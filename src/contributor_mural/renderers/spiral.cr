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
        @sizes[user.login] = spiral.max_size - (spiral.max_size - spiral.min_size) * t
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

    # Share of the disc the avatars may cover. A phyllotaxis packs tightly
    # but its nearest neighbours are several indices apart, so the usable
    # figure sits well below the theoretical circle-packing limit; this is the
    # densest value that keeps avatars from touching (see the overlap spec).
    DENSITY = 0.62

    # Vogel's model for the angle, but the radius grows with the area already
    # placed rather than plain sqrt(i). That keeps the spacing tight while the
    # avatars are shrinking: big ones push their neighbours out, small ones
    # tuck in close.
    private def place(users : Array(EmbeddedUser)) : Array(Spot)
      spiral = @config.spiral
      ranked = users.sort_by { |user| {-user.weight, user.login.downcase} }

      covered = 0.0
      center_size = ranked.empty? ? 0.0 : size_for(ranked.first.login)

      ranked.map_with_index do |user, index|
        size = size_for(user.login)
        radius = Math.sqrt(covered / (Math::PI * DENSITY))
        # The area estimate assumes uniform density, which under-spaces the
        # first few against a much larger centre avatar.
        if index.positive?
          radius = Math.max(radius, (center_size + size) / 2 + spiral.gap)
        end
        covered += Math::PI * ((size + spiral.gap) / 2) ** 2
        {
          user:   user,
          size:   size,
          radius: radius,
          angle:  index * GOLDEN_ANGLE,
        }
      end
    end

    private def size_for(login : String) : Float64
      @sizes[login]? || @config.spiral.max_size.to_f
    end
  end
end
