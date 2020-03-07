# Monkeypatch in fix for OpenSSL::Digest on multibyte strings
class OpenSSL::Digest
  def update(data : String | Slice)
    LibCrypto.evp_digestupdate(self, data, data.bytesize)
    self
  end
end

module SignatureVerification
  class Error < Exception
  end

  def initialize(@context : HTTP::Server::Context)
  end

  # Verify HTTP signatures according to https://tools.ietf.org/html/draft-cavage-http-signatures-06.
  # In this specific implementation keyId is the URL to either an ActivityPub actor or
  # a [Web Payments Key](https://web-payments.org/vocabs/security#Key).
  private def verify_signature : {String, Actor, String}
    signature_header = request.headers["Signature"]?
    error(401, "Request not signed: no Signature header") unless signature_header

    signature_params = parse_signature(signature_header)

    key_id = signature_params["keyId"]?
    error(400, "Invalid Signature: keyId not present") unless key_id

    signature = signature_params["signature"]?
    error(400, "Invalid Signature: signature not present") unless signature

    # NOTE: `actor_from_key_id` can take time performing a HTTP request, so it should
    # complete before `build_signed_string`, which can load the request body into memory.
    actor = actor_from_key_id(key_id)

    error(400, "No request body") unless body = request.body

    body = String.build do |io|
      copy_size = IO.copy(body, io, 4_096_000)
      error(400, "Request body too large") if copy_size == 4_096_000
    end

    signed_string = build_signed_string(body, signature_params["headers"]?)

    # pp actor
    public_key = OpenSSL::PKey::RSA.new(actor.public_key.public_key_pem, is_private: false)

    begin
      signature = Base64.decode(signature)
    rescue err : Base64::Error
      error(400, "Invalid Signature: Invalid base64 in signature value")
    end

    if public_key.verify(OpenSSL::Digest.new("SHA256"), signature, signed_string)
      {body, actor, key_id}
    else
      actor = actor_from_key_id(key_id, false)
      public_key = OpenSSL::PKey::RSA.new(actor.public_key.public_key_pem, is_private: false)
      if public_key.verify(OpenSSL::Digest.new("SHA256"), signature, signed_string)
        {body, actor, key_id}
      else
        error(401, "Invalid Signature: cryptographic signature did not verify for #{key_id.inspect}")
      end
    end
  end

  private def parse_signature(signature) : Hash(String, String)
    params = Hash(String, String).new

    signature.split(',') do |param|
      parts = param.split('=', 2)
      unless parts.size == 2
        error(400, "Invalid Signature: param #{param.strip.inspect} did not contain '='")
      end

      # This is an 'auth-param' defined in https://tools.ietf.org/html/rfc7235#section-2.1
      key = parts[0].strip
      value = parts[1].strip

      if value.starts_with? '"'
        unless value.ends_with?('"') && value.size > 2
          error(400, "Invalid Signature: malformed quoted-string in param #{param.strip.inspect}")
        end

        value = HTTP.dequote_string(value[1..-2]) rescue nil
        unless value
          error(400, "Invalid Signature: malformed quoted-string in param #{param.strip.inspect}")
        end
      end

      params[key] = value
    end

    params
  end

  CACHE_EXPIRE_SECOND = 2.day.to_i;

  private def cached_fetch_json(url, json_class : JsonType.class, use_cache = true) : JsonType forall JsonType
    remote_actor_key = "remote_actor:cache:#{url}"
    remote_actor_body = use_cache ? PubRelay.redis.get(remote_actor_key) : nil
    if remote_actor_body
      puts "use cache: #{remote_actor_key}"
      PubRelay.redis.expire(remote_actor_key, SignatureVerification::CACHE_EXPIRE_SECOND)
    else
      puts "no cache: #{remote_actor_key}"
      headers = HTTP::Headers{"Accept" => "application/activity+json, application/ld+json"}
      # TODO use HTTP::Client.new and set read timeout
      response = HTTP::Client.get(url, headers: headers)
      unless response.status_code == 200
        error(400, "Got non-200 response from fetching #{url.inspect}")
      end
      remote_actor_body = response.body
      PubRelay.redis.setex(remote_actor_key, SignatureVerification::CACHE_EXPIRE_SECOND, remote_actor_body)
    end
    JsonType.from_json(remote_actor_body)
  end

  private def actor_from_key_id(key_id, use_cache = true) : Actor
    # Signature keyId is actually the URL
    case key = cached_fetch_json(key_id, Actor | Key, use_cache)
    when Key
      actor = cached_fetch_json(key.owner, Actor, use_cache)
      actor.public_key = key
      actor
    when Actor
      key
    else
      raise "BUG: cached_fetch_json returned neither Actor nor Key"
    end
  rescue ex : JSON::Error
    error(400, "Invalid JSON from fetching #{key_id.inspect}\n#{ex.inspect_with_backtrace}")
  end

  private def build_signed_string(body, signed_headers)
    signed_headers ||= "date"

    signed_headers.split(' ').join('\n') do |header_name|
      case header_name
      when "(request-target)"
        "(request-target): #{request.method.downcase} #{request.resource}"
      when "digest"
        body_digest = OpenSSL::Digest.new("SHA256")
        body_digest.update(body)
        "digest: SHA-256=#{Base64.strict_encode(body_digest.digest)}"
      else
        request_header = request.headers[header_name]?
        unless request_header
          error(400, "Header #{header_name.inspect} was supposed to be signed but was missing from the request")
        end
        "#{header_name}: #{request_header}"
      end
    end
  end

  private def error(status_code, message)
    PubRelay.logger.info "Returned error to client: #{message} #{status_code}"

    response.status_code = status_code
    response.puts message

    raise SignatureVerification::Error.new
  end

  private def request
    @context.request
  end

  private def response
    @context.response
  end
end
