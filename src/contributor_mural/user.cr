module ContributorMural
  # A user after merging config entries and API contributors.
  struct ResolvedUser
    getter login : String
    getter name : String
    getter link : String
    getter avatar_url : String?
    getter weight : Int32
    getter role : String?
    getter group : String?
    # Per-user size multiplier; 1.0 unless the config asked for emphasis.
    getter scale : Float64

    def initialize(@login, @name = login, @link = "https://github.com/#{login}",
                   @avatar_url = nil, @weight = 1, @role = nil, @group = nil,
                   @scale = 1.0)
    end
  end

  # A user whose avatar has been fetched and encoded, ready for rendering.
  struct EmbeddedUser
    getter user : ResolvedUser
    getter data_uri : String

    delegate login, name, link, weight, role, group, scale, to: @user

    def initialize(@user, @data_uri)
    end
  end
end
