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
    # Extra sections this person also appears in, on top of `group`. Empty for
    # everyone the config did not say otherwise about, which is nearly everyone.
    getter also_in : Array(String)
    # Per-user size multiplier; 1.0 unless the config asked for emphasis.
    getter scale : Float64

    def initialize(@login, @name = login, @link = "https://github.com/#{login}",
                   @avatar_url = nil, @weight = 1, @role = nil, @group = nil,
                   @scale = 1.0, @also_in = [] of String)
    end

    # Every section this person is filed under, primary first.
    #
    # One person is one entry all the way through the pipeline — one avatar
    # fetched, one place in the sort, one slot against `limit` — and only the
    # bucketing reads this. Being on two walls is a placement, not a second
    # person.
    def sections : Array(String?)
      return [@group] of String? if @also_in.empty?
      placements = [@group] of String?
      @also_in.each { |group| placements << group unless placements.includes?(group) }
      placements
    end
  end

  # A user whose avatar has been fetched and encoded, ready for rendering.
  struct EmbeddedUser
    getter user : ResolvedUser
    getter data_uri : String

    delegate login, name, link, weight, role, group, also_in, sections, scale, to: @user

    def initialize(@user, @data_uri)
    end
  end
end
