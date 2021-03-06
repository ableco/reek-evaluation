# frozen_string_literal: true

class FeedbackMessage < ApplicationRecord
  include Archivable
  include Rails.application.routes.url_helpers

  # Associations
  belongs_to :weekly_report, optional: true
  belongs_to :receiver_weekly_report, class_name: 'WeeklyReport', optional: true
  belongs_to :sender, class_name: 'User'
  belongs_to :receiver, class_name: 'User'
  belongs_to :feedback_request, optional: true
  has_one :feedback_prompt, through: :feedback_request
  has_many :notifications, as: :notifiable
  has_many :feedback_highlights, -> { where(archived_at: nil) }
  has_one :one_on_one_item, as: :related_resource

  # Validations
  validates :receiver, presence: true, if: :published?
  validates :feedback_request_id,
            uniqueness: {
              scope: [:archived_at],
              message: 'is already assigned to another feedback_message'
            }, allow_nil: true

  # Callbacks
  after_save :update_counter
  after_update :send_slack_notification, if: -> { coaching_tip_created_for_the_first_time? }

  after_save :send_slack_notification_to_receiver, if: -> { feedback_submitted? }
  after_save :send_slack_notification_to_receiver_manager, if: -> { feedback_submitted? }

  after_create :send_slack_notification_on_request_mismatch, if: lambda {
    feedback_request_id?
  }

  # Scopes
  scope :published, -> { where.not(submitted_at: nil) }
  scope :drafts, -> { where(submitted_at: nil) }
  scope :previous_week, -> { where(created_at: previous_week_start..previous_week_end) }

  def self.fix_counts
    published.each(&:update_counter)
  end

  def self.previous_week_start
    1.week.ago.beginning_of_week
  end

  def self.previous_week_end
    1.week.ago.end_of_week
  end

  def self.get_dashboard_info
    dashboard = Dashboard.new
    dashboard.info
  end

  def mark_as_reviewed!
    update!(reviewed_by_manager: Time.current.utc)
  end

  def manager_mark_as_read!
    update!(read_by_manager: Time.current.utc)
    update_manager_counter
  end

  def mark_as_read
    if read_by_receiver.nil?
      update(read_by_receiver: Time.current.utc)
      update_receiver_counter
    end
  end

  def mark_as_read!
    update!(read_by_receiver: Time.current.utc)
    update_receiver_counter
  end

  def mark_as_liked!
    update!(liked: Time.current.utc)
  end

  def highlights
    feedback_highlights
      .includes(expectation: :responsibility)
  end

  def publish!
    update!(submitted_at: Time.zone.now)
  end

  def published?
    submitted_at.present?
  end

  private

  def update_counter
    update_receiver_counter
    update_manager_counter
  end

  def update_receiver_counter
    receiver_counter = receiver.received_feedback_messages.where(read_by_receiver: nil).count
    receiver.update(unread_feedback_messages_by_receiver_count: receiver_counter)
  end

  def update_manager_counter
    manager_counter = receiver.received_feedback_messages.where(read_by_manager: nil).count
    receiver.update(unread_feedback_messages_by_manager_count: manager_counter)
  end

  def self.senders_count(messages)
    messages.uniq(&:sender_id).count
  end

  def send_slack_notification
    manager = sender.manager
    SlackSendMessageJob.perform_later(
      "@#{sender.slack_name}",
      "<@#{manager.slack_id}|#{manager.slack_name}> has added a coaching tip to the feedback you've sent. You can review it by going to :core: #{user_feedback_message_url(sender.id, id)}"
    )
  end

  def coaching_tip_created_for_the_first_time?
    saved_change_to_coaching_tip? && saved_change_to_coaching_tip[0].nil?
  end

  def feedback_submitted?
    saved_change_to_submitted_at? && saved_change_to_submitted_at[0].nil?
  end

  def send_slack_notification_to_receiver
    SlackSendMessageJob.perform_later(
      "@#{receiver.slack_name}",
      "You’ve just received feedback from <@#{sender.slack_id}|#{sender.slack_name}>. To read it, head over to :core: at #{user_feedback_message_url(receiver.id, id)}"
    )
  end

  def send_slack_notification_to_receiver_manager
    return unless receiver.manager_id

    SlackSendMessageJob.perform_later(
      "@#{receiver.manager.slack_name}",
      "<@#{receiver.slack_id}|#{receiver.slack_name}> just received feedback from <@#{sender.slack_id}|#{sender.slack_name}>. To read it, head over to :core: at #{user_feedback_message_url(receiver.id, id)}"
    )
  end

  def send_slack_notification_on_request_mismatch
    return if request_sender? && request_receiver?

    SlackSendMessageJob.perform_later(
      '#core-notifications',
      "Feedback #{id} submitted by user #{sender_id} to #{receiver_id} for request #{feedback_request_id} created by the user #{request_sender.id} to #{request_receiver.id}"
    )
  end

  def request_sender?
    receiver == feedback_request.sender
  end

  def request_receiver?
    sender == feedback_request.receiver
  end
end
