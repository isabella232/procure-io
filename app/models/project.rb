# == Schema Information
#
# Table name: projects
#
#  id                   :integer          not null, primary key
#  title                :string(255)
#  body                 :text
#  bids_due_at          :datetime
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  posted_at            :datetime
#  posted_by_officer_id :integer
#  total_comments       :integer          default(0), not null
#  form_options         :text
#  abstract             :string(255)
#  featured             :boolean
#  review_mode          :integer          default(1)
#

require_dependency 'enum'

class Project < ActiveRecord::Base
  include ActionView::Helpers::TextHelper
  include Behaviors::PostableByOfficer
  include Behaviors::WatchableByUser
  include Behaviors::TargetableForEvents
  include Behaviors::ResponseFieldable

  attr_accessor :updating_officer_id

  self.cache_timestamp_format = :nsec

  is_impressionable

  has_many :bids
  has_many :collaborators, -> { order('created_at') }, dependent: :destroy
  has_many :officers,
           -> { select('officers.*, collaborators.owner as owner').order('created_at').uniq(true) },
           through: :collaborators
  has_many :questions, dependent: :destroy
  has_many :comments, as: :commentable, dependent: :destroy
  has_many :labels, dependent: :destroy
  has_many :amendments, dependent: :destroy
  has_many :project_revisions, -> { order('created_at DESC') }, dependent: :destroy
  has_and_belongs_to_many :tags, after_add: :touch_self, after_remove: :touch_self

  after_update :generate_project_revisions_if_body_changed!

  serialize :form_options, Hash

  scope :featured, -> { where(featured: true) }
  scope :open_for_bids, -> { where("bids_due_at IS NULL OR bids_due_at > ?", Time.now) }
  scope :join_tags, -> { joins("LEFT JOIN projects_tags ON projects.id = projects_tags.project_id INNER JOIN tags ON tags.id = projects_tags.tag_id") }

  has_searcher starting_query: Project.open_for_bids.posted

  pg_search_scope :full_search, against: [:title, :body],
                                associated_against: { amendments: [:title, :body],
                                                      questions: [:body, :answer_body],
                                                      tags: [:name] },
                                using: {
                                  tsearch: {prefix: true}
                                }

  calculator :total_comments do comments end

  def self.review_modes
    @review_modes ||= Enum.new(:stars, :one_through_five)
  end

  def self.add_params_to_query(query, params)
    if !params[:q].blank?
      query = query.full_search(params[:q])
    end

    if !params[:category].blank?
      query = query.join_tags.where("tags.name = ?", params[:category])
    end

    if params[:posted_after]
      query = query.where(posted_at: params[:posted_after]..Time.now)
    end

    if !params[:sort] || !params[:sort].in?(["posted_at", "bids_due_at"])
      params[:sort] = "posted_at"
    end

    query = query.order("#{params[:sort]} #{params[:direction] == 'asc' ? 'asc' : 'desc'}")

    query
  end

  def abstract_or_truncated_body
    !abstract.blank? ? abstract : truncate(self.body, length: 130, omission: "...")
  end

  def owners
    officers.where(collaborators: {owner: true})
  end

  def unread_bids_for_officer(officer)
    bids.submitted.joins("LEFT JOIN bid_reviews on bid_reviews.bid_id = bids.id AND bid_reviews.officer_id = #{officer.id}")
                  .where("bid_reviews.read = false OR bid_reviews.read IS NULL")
  end

  def open_for_bids?
    !bids_due_at || (bids_due_at > Time.now)
  end

  def status
    if !posted_at
      'not_yet_posted'
    elsif bids_due_at && open_for_bids?
      'open_with_due_date'
    elsif bids_due_at && !open_for_bids?
      'closed_with_due_date'
    else
      'open_for_bids'
    end
  end

  def status_badge_class
    case status
    when 'not_yet_posted'
      ''
    when 'open_with_due_date', 'open_for_bids'
      'badge-info'
    when 'closed_with_due_date'
      'badge-warning'
    end
  end

  def status_text
    case status
    when 'not_yet_posted'
      I18n.t('g.not_yet_posted')
    when 'open_with_due_date'
      I18n.t('g.open_for_bids')
    when 'open_for_bids'
      I18n.t('g.open_for_bids')
    when 'closed_with_due_date'
      I18n.t('g.bids_closed')
    end
  end

  def long_status_text
    case status
    when 'not_yet_posted'
      I18n.t('g.not_yet_posted')
    when 'open_with_due_date'
      I18n.t("g.bids_due_on_date", date: bids_due_at.to_formatted_s(:readable))
    when 'open_for_bids'
      I18n.t('g.open_for_bids')
    when 'closed_with_due_date'
      I18n.t("g.bids_were_due_on_date", date: bids_due_at.to_formatted_s(:readable))
    end
  end


  private
  def after_post_by_officer(officer)
    comments.create(officer_id: officer.id,
                    comment_type: "ProjectPosted")

    GlobalConfig.instance.run_event_hooks_for_project!(self)
  end

  def after_unpost_by_officer(officer)
    comments.create(officer_id: officer.id,
                    comment_type: "ProjectUnposted")
  end

  def generate_project_revisions_if_body_changed!
    return unless body_changed?
    project_revisions.create(body: body_was, saved_by_officer_id: updating_officer_id)
  end
end
