# Deterministic avatar source for specs: bytes derive from login and size,
# selected logins fail like a 404.
class FakeAvatarSource < ContributorMural::AvatarSource
  getter fetch_count = 0

  def initialize(@missing : Array(String) = [] of String)
  end

  def url_for(user : ContributorMural::ResolvedUser, size : Int32) : String
    "fake://#{user.avatar_url || user.login}/#{size}"
  end

  def fetch(user : ContributorMural::ResolvedUser, size : Int32) : {Bytes, String}
    @fetch_count += 1
    if @missing.includes?(user.login)
      raise ContributorMural::AvatarError.new("avatar not found (404)", 404)
    end
    {"IMG:#{user.login}:#{size}".to_slice, "image/png"}
  end
end
