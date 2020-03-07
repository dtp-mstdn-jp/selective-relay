class MisskeyUser
  include JSON::Serializable

  getter username : String
  getter host : String?

  def acct(domain = nil)
    hostname = host || domain || ""
    "@#{username}@#{hostname}"
  end
end
