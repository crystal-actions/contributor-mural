module ContributorMural::Renderers
  # Phyllotaxis: the arrangement sunflower seeds use. Each avatar sits one
  # golden angle further around than the last, at a radius growing with the
  # square root of its rank, which spaces them evenly with no rings or rows.
  # Rank also drives size, so the people carrying the project sit large in
  # the middle and the wall thins out toward the edge.
  class Spiral < Renderer
    CLIP_ID = "spiral-clip"
    # 137.50776…°, the angle that keeps successive points from lining up.
    GOLDEN_ANGLE = Math::PI * (3 - Math.sqrt(5.0))

    @sizes = {} of String => Float64

    def prepare(users : Array(ResolvedUser)) : Nil
      spiral = @config.spiral
      ranked = users.sort_by { |user| {-user.weight, user.login.downcase} }
      last = Math.max(ranked.size - 1, 1)
      ranked.each_with_index do |user, index|
        # A power curve below 1 drops quickly among the leaders and then runs
        # nearly flat, so the long tail stays a uniform field of avatars.
        t = (index / last.to_f) ** 0.45
        size = spiral.max_size - (spiral.max_size - spiral.min_size) * t
        # `scale` multiplies the size the taper arrived at, and `place` grows
        # each radius from the area already covered, so an emphasised avatar
        # pushes the rest of the bloom outward instead of landing on it.
        @sizes[user.login] = size * user.scale
      end
    end

    def fetch_size(user : ResolvedUser) : Int32
      (size_for(user.login) * 2).ceil.to_i
    end

    protected def defs(io : String::Builder) : Nil
      shape_clip(io, CLIP_ID, @config.spiral.shape)
    end

    protected def block_size(users : Array(EmbeddedUser)) : {Float64, Float64}
      placements = place(users)
      return {16.0, 16.0} if placements.empty?

      extent = placements.max_of { |spot| spot[:radius] + spot[:size] / 2 }
      side = 2 * extent + @config.spiral.gap
      {side, side}
    end

    protected def draw_block(io : String::Builder, users : Array(EmbeddedUser), y_offset : Float64) : Nil
      placements = place(users)
      return if placements.empty?

      extent = placements.max_of { |spot| spot[:radius] + spot[:size] / 2 }
      center = extent + @config.spiral.gap / 2
      clipped = !@config.spiral.shape.square?

      placements.each do |spot|
        user = spot[:user]
        size = spot[:size]
        x = center + Math.cos(spot[:angle]) * spot[:radius] - size / 2
        y = center + Math.sin(spot[:angle]) * spot[:radius] - size / 2 + y_offset

        io << %(  <a href="#{SVG.escape(user.link)}" target="_blank">\n)
        io << %(    <title>#{SVG.escape(title_for(user))}</title>\n)
        io << %(    <image href="#{user.data_uri}" x="#{SVG.num(x)}" y="#{SVG.num(y)}" width="#{SVG.num(size)}" height="#{SVG.num(size)}" preserveAspectRatio="xMidYMid slice")
        io << %( clip-path="url(##{CLIP_ID})") if clipped
        io << "/>\n"
        io << "  </a>\n"
      end
    end

    private alias Spot = NamedTuple(user: EmbeddedUser, size: Float64, radius: Float64, angle: Float64)

    # Share of the disc the avatars may cover. A phyllotaxis packs tightly but
    # its nearest neighbours are several indices apart, so the usable figure
    # sits well below the theoretical circle-packing limit. This is the opening
    # guess only — `clear_of` is what decides the radius actually used.
    DENSITY = 0.62

    # Vogel's model for the angle, but the radius grows with the area already
    # placed rather than plain sqrt(i). That keeps the spacing tight while the
    # avatars are shrinking: big ones push their neighbours out, small ones
    # tuck in close.
    #
    # The area total is an estimate, and an estimate is all it can be: it
    # assumes the avatars placed so far are spread at a uniform density, which
    # nothing enforces. The centre avatar alone breaks it — everyone on the
    # first turn is pushed out past where the area says they go, leaving a hole
    # the estimate keeps counting as filled, and the ring after that lands on
    # top of the ring before it. The gap widens with the avatars: at the default
    # sizes it costs a pixel or so, and with `max_size` near `min_size` it
    # overlapped by twenty. So every radius the estimate proposes is checked
    # against what is already on the wall before it is used.
    # The list arrives in the order `sort` asked for, and is placed in it: the
    # first person listed takes the centre and the rest bloom outward. Under
    # the default `sort: weight` that is the weight order this used to impose
    # for itself — the same comparator, so a plain wall is unchanged — but
    # `sort: login` and `sort: none` now reach the spiral too, where they were
    # silently dropped. Size still comes from `prepare`, which ranks by weight
    # whatever the list order is, so the taper does not move.
    private def place(users : Array(EmbeddedUser)) : Array(Spot)
      spiral = @config.spiral

      covered = 0.0
      center_size = users.empty? ? 0.0 : size_for(users.first.login)
      spots = Array(Spot).new(users.size)

      users.each_with_index do |user, index|
        size = size_for(user.login)
        angle = index * GOLDEN_ANGLE
        radius = Math.sqrt(covered / (Math::PI * DENSITY))
        # The area estimate assumes uniform density, which under-spaces the
        # first few against a much larger centre avatar.
        if index.positive?
          radius = Math.max(radius, (center_size + size) / 2 + spiral.gap)
          radius = clear_of(spots, size, angle, radius)
        end
        covered += Math::PI * ((size + spiral.gap) / 2) ** 2
        spots << {user: user, size: size, radius: radius, angle: angle}
      end
      spots
    end

    # Slides the avatar out along its own ray until it clears every avatar
    # already placed — a full `gap` from each, not merely not touching. This is
    # what makes the layout exact rather than estimated, so the guarantee holds
    # for any `max_size`/`min_size`/`gap` a config can name and for any `scale`.
    #
    # On a fixed ray the clearance around one neighbour is a quadratic in the
    # radius, so the interval it rules out is closed form. Stepping to the far
    # end of a ruled-out interval can walk into another one, hence the loop —
    # which terminates because the radius only ever grows, and only to one of
    # finitely many interval ends.
    private def clear_of(spots : Array(Spot), size : Float64, angle : Float64, radius : Float64) : Float64
      loop do
        moved = false
        spots.each do |spot|
          wanted = (size + spot[:size]) / 2 + @config.spiral.gap
          # How far the neighbour sits off this ray: further than `wanted` and
          # it cannot be reached at any radius.
          offset = spot[:radius] * Math.sin(angle - spot[:angle])
          reach_squared = wanted * wanted - offset * offset
          next if reach_squared <= 0

          along = spot[:radius] * Math.cos(angle - spot[:angle])
          reach = Math.sqrt(reach_squared)
          next unless radius > along - reach && radius < along + reach

          radius = along + reach
          moved = true
        end
        break radius unless moved
      end
    end

    private def size_for(login : String) : Float64
      @sizes[login]? || @config.spiral.max_size.to_f
    end
  end
end
