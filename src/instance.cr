class Instance
  include JSON::Serializable

  property contact_account : Account

  def contact_acct(domain = nil)
    if domain.nil?
      "@#{contact_account.acct}"
    else
      "@#{contact_account.acct}@#{domain}"
    end
  end
end

struct Account
  include JSON::Serializable

  getter acct : String?
end
