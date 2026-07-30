module ContributorMural::Renderers
  # The wall as a small solar system: the top contributor holds the centre and
  # everyone else orbits at a distance set by their rank. Each ring holds as
  # many avatars as its circumference allows and is rotated against the one
  # inside it, so the layout reads as orbits rather than spokes.
  class Orbit < Renderer
    CLIP_ID = "orbit-clip"

    def fetch_size(user : ResolvedUser) : Int32
      orbit = @config.orbit
      (Math.max(orbit.center_size, orbit.avatar_size) * user.scale * 2).ceil.to_i
    end

    protected def style_rules(palette : Palette) : String
      ".mural-ring{stroke:#{palette.label_color}}"
    end

    protected def defs(io : String::Builder) : Nil
      io << %(  <defs><clipPath id="#{CLIP_ID}" clipPathUnits="objectBoundingBox"><circle cx="0.5" cy="0.5" r="0.5"/></clipPath></defs>\n)
    end

    protected def block_size(users : Array(EmbeddedUser)) : {Float64, Float64}
      layout = place(users)
      return {16.0, 16.0} if layout.empty?

      extent = layout.max_of { |spot| spot[:radius] + spot[:size] / 2 }
      side = 2 * (extent + @config.orbit.gap)
      {side, side}
    end

    protected def draw_block(io : String::Builder, users : Array(EmbeddedUser), y_offset : Float64) : Nil
      layout = place(users)
      return if layout.empty?

      orbit = @config.orbit
      extent = layout.max_of { |spot| spot[:radius] + spot[:size] / 2 }
      center = extent + orbit.gap

      if orbit.rings?
        layout.map { |spot| spot[:radius] }.uniq!.reject!(&.zero?).each do |radius|
          io << %(  <circle cx="#{SVG.num(center)}" cy="#{SVG.num(center + y_offset)}" r="#{SVG.num(radius)}" fill="none" stroke-width="1" stroke-dasharray="3 5" opacity="0.35" #{ring_paint}/>\n)
        end
      end

      layout.each do |spot|
        user = spot[:user]
        size = spot[:size]
        x = center + Math.cos(spot[:angle]) * spot[:radius] - size / 2
        y = center + Math.sin(spot[:angle]) * spot[:radius] - size / 2 + y_offset

        io << %(  <a href="#{SVG.escape(user.link)}" target="_blank">\n)
        io << %(    <title>#{SVG.escape(title_for(user))}</title>\n)
        io << %(    <image href="#{user.data_uri}" x="#{SVG.num(x)}" y="#{SVG.num(y)}" width="#{SVG.num(size)}" height="#{SVG.num(size)}" preserveAspectRatio="xMidYMid slice" clip-path="url(##{CLIP_ID})"/>\n)
        io << "  </a>\n"
      end
    end

    private alias Spot = NamedTuple(user: EmbeddedUser, size: Float64, radius: Float64, angle: Float64)

    # The list arrives in the order `sort` asked for, and is placed in it: the
    # first person listed takes the centre and the rest fill the rings outward.
    # Under the default `sort: weight` that is the weight order this used to
    # impose for itself — the same comparator, so a plain wall is unchanged —
    # but `sort: login` and `sort: none` now reach the orbit too, where they
    # were silently dropped.
    private def place(users : Array(EmbeddedUser)) : Array(Spot)
      orbit = @config.orbit
      return [] of Spot if users.empty?

      spots = [] of Spot
      center_size = orbit.center_size * users.first.scale
      spots << {user: users.first, size: center_size, radius: 0.0, angle: 0.0}

      remaining = users[1..]
      ring = 1
      radius = orbit.center_size / 2.0 + orbit.ring_gap + ring_size(1) / 2
      # How far the emphasised avatars placed so far have pushed everything
      # outward. Carrying the surplus separately keeps the plain layout at the
      # radii it has always had: with no `scale` this stays zero throughout.
      bulge = (center_size - orbit.center_size) / 2

      until remaining.empty?
        size = ring_size(ring)
        # The widest avatar sets the pitch and the clearance for its whole
        # ring, but which people land on the ring depends on that pitch — so
        # settle the two against each other before placing anything. Only
        # growth is fed back, which is what makes this terminate.
        widest = size
        members = remaining
        loop do
          ring_radius = radius + bulge + (widest - size) / 2
          capacity = ring_capacity(ring_radius, widest + orbit.gap)
          members = remaining.first(Math.min(capacity, remaining.size))
          grown = members.max_of { |user| size * user.scale }
          break if grown <= widest
          widest = grown
        end

        ring_radius = radius + bulge + (widest - size) / 2
        remaining = remaining[members.size..]

        # Half-step rotation per ring keeps avatars off the previous ring's
        # radii; the -90° start puts the first of each ring at the top.
        offset = -Math::PI / 2 + (ring.odd? ? Math::PI / members.size : 0.0)
        members.each_with_index do |user, index|
          angle = offset + index * (2 * Math::PI / members.size)
          spots << {user: user, size: size * user.scale, radius: ring_radius, angle: angle}
        end

        # Half the surplus sits inside the ring and half outside it.
        bulge += widest - size
        ring += 1
        # This ring's own half, the gap, and the next ring's half — which is
        # the next ring's size, not the one after it.
        radius += size / 2 + orbit.ring_gap + ring_size(ring) / 2
      end
      spots
    end

    # Avatars shrink a little each ring out, never past `min_size`.
    private def ring_size(ring : Int32) : Float64
      orbit = @config.orbit
      Math.max(orbit.avatar_size - (ring - 1) * 6.0, orbit.min_size.to_f)
    end

    # How many avatars of the given pitch fit on a ring.
    #
    # What has to clear between two neighbours is the straight line between
    # them, not the arc the ring was measured along. The two agree to within a
    # percent once a ring holds a dozen and not at all when it holds two, where
    # an arc of half the circumference is a chord of the diameter — 36%
    # shorter. Counting arcs let a ring take on one avatar more than fits, and
    # a ring holding two or three of them overlapped outright.
    private def ring_capacity(ring_radius : Float64, pitch : Float64) : Int32
      return 1 unless ring_radius > 0 && pitch > 0
      # `count` avatars sit `2r * sin(pi / count)` apart, so the largest count
      # whose chord still clears the pitch is `pi / asin(pitch / 2r)`. Past a
      # ratio of 1 not even two of them fit facing each other.
      ratio = pitch / (2 * ring_radius)
      return 1 if ratio >= 1.0
      Math.max((Math::PI / Math.asin(ratio)).floor.to_i, 1)
    end

    private def ring_paint : String
      mode.auto? ? %(class="mural-ring") : %(stroke="#{SVG.escape(palette.label_color)}")
    end
  end
end
