module ContributorMural::Renderers
  # The wall as a small solar system: the top contributor holds the centre and
  # everyone else orbits at a distance set by their rank. Each ring holds as
  # many avatars as its circumference allows and is rotated against the one
  # inside it, so the layout reads as orbits rather than spokes.
  class Orbit < Renderer
    CLIP_ID = "orbit-clip"

    def fetch_size(user : ResolvedUser) : Int32
      orbit = @config.orbit
      Math.max(orbit.center_size, orbit.avatar_size) * 2
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

    private def place(users : Array(EmbeddedUser)) : Array(Spot)
      orbit = @config.orbit
      ranked = users.sort_by { |user| {-user.weight, user.login.downcase} }
      return [] of Spot if ranked.empty?

      spots = [] of Spot
      spots << {user: ranked.first, size: orbit.center_size.to_f, radius: 0.0, angle: 0.0}

      remaining = ranked[1..]
      ring = 1
      radius = orbit.center_size / 2.0 + orbit.ring_gap + orbit.avatar_size / 2.0

      until remaining.empty?
        # Avatars shrink a little each ring out, never past `min_size`.
        size = Math.max(orbit.avatar_size - (ring - 1) * 6.0, orbit.min_size.to_f)
        capacity = Math.max((2 * Math::PI * radius / (size + orbit.gap)).floor.to_i, 1)
        members = remaining.first(Math.min(capacity, remaining.size))
        remaining = remaining[members.size..]

        # Half-step rotation per ring keeps avatars off the previous ring's
        # radii; the -90° start puts the first of each ring at the top.
        offset = -Math::PI / 2 + (ring.odd? ? Math::PI / members.size : 0.0)
        members.each_with_index do |user, index|
          angle = offset + index * (2 * Math::PI / members.size)
          spots << {user: user, size: size, radius: radius, angle: angle}
        end

        ring += 1
        radius += size / 2 + orbit.ring_gap + Math.max(orbit.avatar_size - ring * 6.0, orbit.min_size.to_f) / 2
      end
      spots
    end

    private def ring_paint : String
      mode.auto? ? %(class="mural-ring") : %(stroke="#{SVG.escape(palette.label_color)}")
    end
  end
end
