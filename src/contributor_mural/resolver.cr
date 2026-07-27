module ContributorMural
  # Merges config users and API contributors into the final render list.
  # Pure: takes already-fetched contributor data, performs no IO.
  module Resolver
    def self.resolve(config : Config, api_users : Array(ResolvedUser) = [] of ResolvedUser) : Array(ResolvedUser)
      merged = merge_api_users(api_users)
      api_by_login = merged.index_by(&.login.downcase)
      seen = Set(String).new
      result = [] of ResolvedUser

      unless config.users.empty?
        config.users.each do |entry|
          key = entry.login.downcase
          result << from_entry(entry, api_by_login[key]?)
          seen << key
        end
      end

      # Whatever the runner fetched (contributors, members, stargazers,
      # sponsors) merges in behind the curated list.
      merged.each do |user|
        result << user if seen.add?(user.login.downcase)
      end

      result.reject! { |user| excluded?(user.login, config.exclude) }
      result = sort(result, config.sort)
      config.limit.try { |lim| result = result.first(lim) }
      result
    end

    # Entries are matched case-insensitively, exactly unless they carry a
    # wildcard. Bare logins stay a plain comparison so nothing that used to
    # match can stop matching.
    private def self.excluded?(login : String, patterns : Array(String)) : Bool
      subject = login.downcase
      patterns.any? do |pattern|
        candidate = pattern.downcase
        if candidate.includes?('*') || candidate.includes?('?')
          glob?(subject, candidate)
        else
          subject == candidate
        end
      end
    end

    # `*` (any run, possibly empty) and `?` (one character), and nothing else.
    # Deliberately not `File.match?`: its `[...]` character classes would read
    # the obvious `*[bot]` as "ends with b, o, or t" and silently drop real
    # people, and a deny-list that quietly over-matches is worse than none.
    private def self.glob?(text : String, pattern : String) : Bool
      chars = text.chars
      wildcards = pattern.chars
      at = 0
      cursor = 0
      star = -1
      resume = 0

      while at < chars.size
        if cursor < wildcards.size && (wildcards[cursor] == '?' || wildcards[cursor] == chars[at])
          at += 1
          cursor += 1
        elsif cursor < wildcards.size && wildcards[cursor] == '*'
          # Remember where to backtrack to, then try matching nothing first.
          star = cursor
          resume = at
          cursor += 1
        elsif star >= 0
          # Let the last `*` swallow one more character and retry.
          resume += 1
          at = resume
          cursor = star + 1
        else
          return false
        end
      end

      # Trailing stars can still match the empty remainder.
      while cursor < wildcards.size && wildcards[cursor] == '*'
        cursor += 1
      end
      cursor == wildcards.size
    end

    # Someone can be a contributor *and* a sponsor. Keep one entry per login,
    # in first-seen order, taking the highest weight and the first group so
    # neither source silently drops the person or their standing.
    private def self.merge_api_users(api_users : Array(ResolvedUser)) : Array(ResolvedUser)
      order = [] of String
      by_login = {} of String => ResolvedUser

      api_users.each do |user|
        key = user.login.downcase
        if existing = by_login[key]?
          by_login[key] = ResolvedUser.new(
            login: existing.login,
            name: existing.name,
            link: existing.link,
            avatar_url: existing.avatar_url || user.avatar_url,
            weight: Math.max(existing.weight, user.weight),
            role: existing.role || user.role,
            group: existing.group || user.group,
            scale: Math.max(existing.scale, user.scale),
          )
        else
          order << key
          by_login[key] = user
        end
      end
      order.map { |key| by_login[key] }
    end

    # Config entries win over API data field by field; API fills the gaps
    # (e.g. contribution count as weight, canonical avatar URL). `group` is
    # deliberately not inherited: placement is the config's call, and an
    # entry without `group` belongs to the untitled leading section.
    private def self.from_entry(entry : UserEntry, base : ResolvedUser?) : ResolvedUser
      ResolvedUser.new(
        login: entry.login,
        name: entry.name || base.try(&.name) || entry.login,
        link: entry.link || "https://github.com/#{entry.login}",
        avatar_url: entry.avatar_url || base.try(&.avatar_url),
        weight: entry.weight || base.try(&.weight) || 1,
        role: entry.role || base.try(&.role),
        group: entry.group,
        scale: entry.scale || 1.0,
      )
    end

    # Splits embedded users into ordered (title, members) sections. Ungrouped
    # users come first without a heading; explicit `groups` fixes the order,
    # otherwise groups appear as first mentioned in the config.
    def self.grouped(users : Array(EmbeddedUser), config : Config) : Array({String?, Array(EmbeddedUser)})
      order = group_order(config)
      users.each do |user|
        order << user.group unless order.includes?(user.group)
      end
      order.compact_map do |group|
        members = users.select { |user| user.group == group }
        {group, members} unless members.empty?
      end
    end

    private def self.group_order(config : Config) : Array(String?)
      order = [nil] of String?
      if explicit = config.groups
        explicit.each { |group| order << group }
      else
        config.users.each do |user|
          if group = user.group
            order << group unless order.includes?(group)
          end
        end
        {
          config.contributors.try(&.group),
          config.members.try(&.group),
          config.stargazers.try(&.group),
          config.sponsors.try(&.group),
        }.each do |group|
          order << group if group && !order.includes?(group)
        end
      end
      order
    end

    private def self.sort(users : Array(ResolvedUser), mode : SortMode) : Array(ResolvedUser)
      case mode
      in .weight? then users.sort_by { |user| {-user.weight, user.login.downcase} }
      in .login?  then users.sort_by(&.login.downcase)
      in .none?   then users
      end
    end
  end
end
