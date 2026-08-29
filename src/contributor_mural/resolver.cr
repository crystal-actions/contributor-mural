module ContributorMural
  # Merges config users and API contributors into the final render list.
  # Pure: takes already-fetched contributor data, performs no IO.
  module Resolver
    def self.resolve(config : Config, api_users : Array(ResolvedUser) = [] of ResolvedUser) : Array(ResolvedUser)
      merged = merge_api_users(api_users)
      api_by_login = merged.index_by(&.login.downcase)
      seen = Set(String).new
      result = [] of ResolvedUser

      curated = Set(String).new
      unless config.users.empty?
        config.users.each do |entry|
          key = entry.login.downcase
          result << from_entry(entry, api_by_login[key]?)
          seen << key
          curated << key
        end
      end

      # Whatever the runner fetched (contributors, members, stargazers,
      # sponsors) merges in behind the curated list.
      merged.each do |user|
        result << user if seen.add?(user.login.downcase)
      end

      # Lower-cased once rather than once per user tested against them.
      patterns = config.exclude.map(&.downcase)
      result.reject! { |user| excluded?(user.login, patterns) }
      result = sort(result, config.sort)
      config.limit.try { |lim| result = apply_limit(result, lim, curated) }
      result
    end

    # `limit` caps the wall, and used to cap it by rank alone — so a
    # contributor with a thousand commits could push someone written down in
    # `users:` off the end, and the curated list that is documented as always
    # winning quietly lost. A name in `users:` is a decision already made; the
    # cap spends what is left of itself on everybody else.
    #
    # Render order does not move: the survivors come back in the order `sort`
    # put them in, which is what keeps `limit` from doubling as a second sort.
    private def self.apply_limit(users : Array(ResolvedUser), limit : Int32,
                                 curated : Set(String)) : Array(ResolvedUser)
      return users if users.size <= limit
      return users.first(limit) if curated.empty?

      # Downcased once per user rather than once per test: three of these
      # passes used to build a throwaway String for every login they looked at.
      keyed = users.map { |user| {user, curated.includes?(user.login.downcase)} }
      wanted = keyed.count { |(_user, curated_entry)| curated_entry }

      if wanted >= limit
        # Nothing left to spend, and `limit` is still a cap — so it cuts into
        # the curated list itself. Said out loud, because this is the one case
        # where writing a name down is not enough to keep it.
        #
        # Counted as "still on the wall", not as "listed in `users:`": `exclude`
        # runs first, so the two numbers differ and quoting the config's own
        # would send someone to a file where it does not appear.
        if (dropped = wanted - limit) > 0
          Annotations.warning("`limit: #{limit}` is below the #{wanted} curated people still on " \
                              "the wall — #{dropped} of them #{dropped == 1 ? "is" : "are"} not " \
                              "in the mural")
        end
        return keyed.compact_map { |(user, curated_entry)| user if curated_entry }.first(limit)
      end

      room = limit - wanted
      keyed.compact_map do |(user, curated_entry)|
        next user if curated_entry
        next unless room > 0
        room -= 1
        user
      end
    end

    # Entries are matched case-insensitively, exactly unless they carry a
    # wildcard. Bare logins stay a plain comparison so nothing that used to
    # match can stop matching. `patterns` arrives already lower-cased.
    private def self.excluded?(login : String, patterns : Array(String)) : Bool
      return false if patterns.empty?
      subject = login.downcase
      patterns.any? do |candidate|
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
    # in first-seen order, taking the highest weight and the first group and
    # role so neither source silently drops the person or their standing.
    #
    # Field by field rather than whole-source, now that each source can assert
    # its own `role`: `contributors: group: Contributors` next to `sponsors:
    # role: Sponsor` files the person under Contributors and still says they
    # sponsor, which is what writing both of those down asks for. Sources are
    # consulted in a fixed order — contributors, members, stargazers, sponsors
    # — so a field two of them name comes from the earlier one.
    #
    # The first group is still the only group, even though a person can now be
    # filed under several: appearing on two walls is opt-in, and nobody opts in
    # by enabling a second source. Turning `sponsors:` on would otherwise
    # re-file every sponsor who also has commits, quietly and everywhere at
    # once. `also_in` is unioned rather than dropped so nothing on this path can
    # lose a placement, though no API source sets one today.
    private def self.merge_api_users(api_users : Array(ResolvedUser)) : Array(ResolvedUser)
      order = [] of String
      by_login = {} of String => ResolvedUser

      api_users.each do |user|
        key = user.login.downcase
        if existing = by_login[key]?
          by_login[key] = ResolvedUser.new(
            login: existing.login,
            name: display_name(existing, user),
            link: existing.link,
            avatar_url: existing.avatar_url || user.avatar_url,
            weight: Math.max(existing.weight, user.weight),
            role: existing.role || user.role,
            group: existing.group || user.group,
            also_in: (existing.also_in + user.also_in).uniq!,
            scale: Math.max(existing.scale, user.scale),
          )
        else
          order << key
          by_login[key] = user
        end
      end
      order.map { |key| by_login[key] }
    end

    # `name` has no nil to fall back through: a source that does not report one
    # leaves the login standing in for it. So first-wins alone would let the
    # contributors API — which never returns a name — shadow the display name
    # a sponsor entry did carry. A login repeated as a name is the gap, and is
    # filled like the other gaps around it.
    private def self.display_name(existing : ResolvedUser, other : ResolvedUser) : String
      return existing.name unless existing.name == existing.login
      other.name == other.login ? existing.name : other.name
    end

    # Config entries win over API data field by field; API fills the gaps
    # (e.g. contribution count as weight, canonical avatar URL, and the `role`
    # the source named for everyone it yields). `group` and `also_in` are
    # deliberately not inherited: placement is the config's call, and an entry
    # without `group` belongs to the untitled leading section.
    private def self.from_entry(entry : UserEntry, base : ResolvedUser?) : ResolvedUser
      ResolvedUser.new(
        login: entry.login,
        name: entry.name || base.try(&.name) || entry.login,
        link: entry.link || "https://github.com/#{entry.login}",
        avatar_url: entry.avatar_url || base.try(&.avatar_url),
        weight: entry.weight || base.try(&.weight) || 1,
        role: entry.role || base.try(&.role),
        group: entry.group,
        also_in: entry.also_in || [] of String,
        scale: entry.scale || 1.0,
      )
    end

    # Splits embedded users into ordered (title, members) sections. Ungrouped
    # users come first without a heading; explicit `groups` fixes the order,
    # otherwise groups appear as first mentioned in the config.
    #
    # This is the one place a person can land in more than one bucket. Everything
    # upstream — the fetch, the sort, the `limit` — has already treated them as
    # the single person they are; `also_in` only decides how many times that one
    # entry is drawn.
    def self.grouped(users : Array(EmbeddedUser), config : Config) : Array({String?, Array(EmbeddedUser)})
      # Bucketed in one pass rather than re-scanning the whole list once per
      # group. `order` decides what is emitted and in what sequence, exactly as
      # it did when this filtered the list instead of bucketing it.
      members = {} of String? => Array(EmbeddedUser)
      order = group_order(config)
      users.each do |user|
        user.sections.each do |group|
          (members[group] ||= [] of EmbeddedUser) << user
          order << group unless order.includes?(group)
        end
      end
      order.compact_map do |group|
        if bucket = members[group]?
          {group, bucket} unless bucket.empty?
        end
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
          user.also_in.try &.each do |extra|
            order << extra unless order.includes?(extra)
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
