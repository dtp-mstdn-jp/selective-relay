require "./inbox_handler"

class ActivityFilter
  property domain : String = ""

  def initialize(@actor : Actor, @activity : Activity)
    @attachments = activity.attachments || [] of Activity::Attachment
    @hashtag_names = activity.hashtag_names || [] of String
  end

  def reject_delivery?
    return true if same_domain? || reject_service? || no_allow_domain? || deny_domain? || deny_old_published?
    return true if reject_subscribe_delivery?
    return true if with_content? && (reject_have_attachment? || reject_not_have_hashtag? || no_allow_hashtag? || deny_hashtag?)
    false
  end

  def reject_subscribe_delivery?
    return true if send_deny_domain?
    return true if user_send_deny_domain? || user_send_disabled?
    false
  end

  WITH_CONTENT_TYPES = {"Create", "Announce"}

  private def with_content?
    @activity.types.any? { |type| WITH_CONTENT_TYPES.includes? type }
  end

  private def same_domain?
    domain == @actor.domain
  end

  private def no_allow_domain?
    key = "allow_domain:#{domain}"
    redis.scard(key) > 0 && redis.sismember(key, @actor.domain) == 0
  end

  private def deny_domain?
    redis.sismember("deny_domain:#{domain}", @actor.domain) == 1
  end

  private def deny_old_published?
    if (published = @activity.published)
      published < Time.utc - 10.minutes
    end
  end

  private def reject_not_have_hashtag?
    #    redis.hexists("options:#{domain}", "hashtag_required") == 1 && @hashtag_names.size == 0
    @hashtag_names.size == 0
  end

  private def no_allow_hashtag?
    key = "allow_hashtag:#{domain}"
    redis.scard(key) > 0 && !redis.smembers(key).any? { |tag| @hashtag_names.includes? tag.to_s.downcase }
  end

  private def deny_hashtag?
    redis.smembers("deny_hashtag:#{domain}").any? { |tag| @hashtag_names.includes? tag.to_s.downcase }
  end

  private def reject_have_attachment?
    redis.hexists("options:#{domain}", "reject_attachment") == 1 && @attachments.size > 0
  end

  private def reject_service?
    redis.hexists("options:#{domain}", "reject_service") == 1 && @actor.actor_type == "Service"
  end

  private def user_send_deny_domain?
    redis.sismember("user_options:send:deny:domains:#{@actor.acct}", domain) == 1
  end

  private def user_send_disabled?
    redis.hget("user_options:others:#{@actor.acct}", "disabled") == "true"
  end

  private def send_deny_domain?
    redis.sismember("options:send:deny:domains:#{@actor.domain}", domain) == 1
  end

  # TODO: max_content_length
  # TODO: min_content_length

  private def redis
    PubRelay.redis
  end

end
