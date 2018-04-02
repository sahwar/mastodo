# frozen_string_literal: true

class NotifyService < BaseService
  def call(recipient, activity)
    @recipient    = recipient
    @activity     = activity
    @notification = Notification.new(account: @recipient, activity: @activity)

    return if recipient.user.nil? || blocked?

    create_notification
    send_email if email_enabled?
  rescue ActiveRecord::RecordInvalid
    return
  end

  private

  def visibility
    return @visibility if defined?(@visibility)
    unless @activity.is_a?(Follow) || @activity.is_a?(FollowRequest)
      status = @activity.is_a?(Status) ? @activity : @activity.status
      @visibility = status.visibility
    end
    @visibility
  end

  def blocked_mention?
    FeedManager.instance.filter?(:mentions, @notification.mention.status, @recipient.id)
  end

  def blocked_favourite?
    false
  end

  def blocked_follow?
    false
  end

  def blocked_reblog?
    @recipient.muting_reblogs?(@notification.from_account)
  end

  def blocked_follow_request?
    false
  end

  def following_sender?
    return @following_sender if defined?(@following_sender)
    @following_sender = @recipient.following?(@notification.from_account) || @recipient.requested?(@notification.from_account)
  end

  def optional_non_follower?
    @recipient.user.settings.interactions['must_be_follower']  && !@notification.from_account.following?(@recipient)
  end

  def optional_non_following?
    @recipient.user.settings.interactions['must_be_following'] && !following_sender?
  end

  def direct_message?
    @notification.type == :mention && @notification.target_status.direct_visibility?
  end

  def response_to_recipient?
    @notification.target_status.in_reply_to_account_id == @recipient.id && @notification.target_status.thread&.direct_visibility?
  end

  def optional_non_following_and_direct?
    direct_message? &&
      @recipient.user.settings.interactions['must_be_following_dm'] &&
      !following_sender? &&
      !response_to_recipient?
  end

  def optional_non_following_and_too_young?
    @recipient.user.settings.interactions['must_be_one_day_old'] &&
      Time.now - @notification.from_account.created_at < 1.days &&
      !following_sender? &&
      !response_to_recipient?
  end

  def hellbanned?
    @notification.from_account.silenced? && !following_sender?
  end

  def from_self?
    @recipient.id == @notification.from_account.id
  end

  def domain_blocking?
    @recipient.domain_blocking?(@notification.from_account.domain) && !following_sender?
  end

  def blocked?
    blocked   = @recipient.suspended?                            # Skip if the recipient account is suspended anyway
    blocked ||= from_self?                                       # Skip for interactions with self
    blocked ||= domain_blocking?                                 # Skip for domain blocked accounts
    blocked ||= @recipient.blocking?(@notification.from_account) # Skip for blocked accounts
    blocked ||= @recipient.muting_notifications?(@notification.from_account)
    blocked ||= hellbanned?                                      # Hellban
    blocked ||= optional_non_follower?                           # Options
    blocked ||= optional_non_following?                          # Options
    blocked ||= optional_non_following_and_direct?               # Options
    blocked ||= optional_non_following_and_too_young?            # Options
    blocked ||= conversation_muted?
    blocked ||= send("blocked_#{@notification.type}?")           # Type-dependent filters
    blocked
  end

  def conversation_muted?
    if @notification.target_status
      @recipient.muting_conversation?(@notification.target_status.conversation)
    else
      false
    end
  end

  def create_notification
    @notification.save!
    return unless @notification.browserable?
    Redis.current.publish("timeline:#{@recipient.id}", Oj.dump(event: :notification, payload: InlineRenderer.render(@notification, @recipient, :notification)))
    send_push_notifications
  end

  def send_push_notifications
    # HACK: Can be caused by quickly unfavouriting a status, since creating
    # a favourite and creating a notification are not wrapped in a transaction.
    return if @notification.activity.nil?

    sessions_with_subscriptions = @recipient.user.session_activations.where.not(web_push_subscription: nil)
    sessions_with_subscriptions_ids = sessions_with_subscriptions.select { |session| session.web_push_subscription.pushable? @notification }.map(&:id)

    WebPushNotificationWorker.push_bulk(sessions_with_subscriptions_ids) do |session_activation_id|
      [session_activation_id, @notification.id]
    end
  end

  def send_email
    NotificationMailer.public_send(@notification.type, @recipient, @notification).deliver_later
  end

  def email_enabled?
    @recipient.user.settings.notification_emails[@notification.type.to_s]
  end
end
