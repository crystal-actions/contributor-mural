module ContributorMural::Renderers
  # Classic avatar wall: fixed-size avatars in rows, optional name labels and
  # a smaller role line beneath them.
  class Grid < Renderer
    LABEL_HEIGHT = 18
    ROLE_HEIGHT  = 14
    CLIP_ID      = "avatar-clip"

    def fetch_size(user : ResolvedUser) : Int32
      @config.grid.avatar_size * 2
    end

    protected def title_inset : Float64
      @config.grid.margin + gutter_for(nil)
    end

    protected def defs(io : String::Builder) : Nil
      shape_clip(io, CLIP_ID, @config.grid.shape)
    end

    protected def block_size(users : Array(EmbeddedUser)) : {Float64, Float64}
      grid = @config.grid
      cols = Math.min(grid.columns, users.size)
      rows = (users.size + cols - 1) // cols
      cell_h = grid.avatar_size + label_height(users)
      width = cols * grid.avatar_size + (cols + 1) * grid.margin
      height = rows * cell_h + (rows + 1) * grid.margin
      # Labels are centered on their cell and may be wider than the avatar, so
      # the block gets a gutter on both sides for the overhang.
      {width + 2 * gutter_for(users), height.to_f}
    end

    protected def draw_block(io : String::Builder, users : Array(EmbeddedUser), y_offset : Float64) : Nil
      grid = @config.grid
      cols = Math.min(grid.columns, users.size)
      cell_w = grid.avatar_size
      cell_h = grid.avatar_size + label_height(users)
      clipped = !grid.shape.square?
      gutter = gutter_for(users)

      users.each_with_index do |user, index|
        row, col = index.divmod(cols)
        x = gutter + grid.margin + col * (cell_w + grid.margin)
        y = grid.margin + row * (cell_h + grid.margin) + y_offset

        io << %(  <a href="#{SVG.escape(user.link)}" target="_blank">\n)
        io << %(    <title>#{SVG.escape(title_for(user))}</title>\n)
        io << %(    <image href="#{user.data_uri}" x="#{SVG.num(x)}" y="#{SVG.num(y)}" width="#{grid.avatar_size}" height="#{grid.avatar_size}" preserveAspectRatio="xMidYMid slice")
        io << %( clip-path="url(##{CLIP_ID})") if clipped
        io << "/>\n"
        if grid.show_names?
          center = x + cell_w / 2
          label(io, name_label(user), center, y + grid.avatar_size + 13)
          if role = role_label(user)
            io << %(    <text x="#{SVG.num(center)}" y="#{SVG.num(y + grid.avatar_size + 26)}" text-anchor="middle" font-family="#{SVG.escape(theme.font_family)}" font-size="9" #{role_paint}>#{SVG.escape(role)}</text>\n)
          end
        end
        io << "  </a>\n"
      end
    end

    private def name_label(user : EmbeddedUser) : String
      truncate(user.name, @config.grid.truncate)
    end

    # Roles get a little more room than names; `truncate: 0` disables both.
    private def role_label(user : EmbeddedUser) : String?
      role = user.role
      return unless role
      limit = @config.grid.truncate
      truncate(role, limit <= 0 ? 0 : limit + 4)
    end

    # Half of how far the widest label sticks out past its cell.
    private def gutter_for(users : Array(EmbeddedUser)?) : Float64
      grid = @config.grid
      return 0.0 unless users && grid.show_names?

      widest = users.max_of? do |user|
        name_width = text_width(name_label(user), 11.0)
        role_width = (role = role_label(user)) ? text_width(role, 9.0) : 0.0
        Math.max(name_width, role_width)
      end
      return 0.0 unless widest
      Math.max(widest - grid.avatar_size, 0.0) / 2
    end

    # Sections where at least one member has a role get a taller label area.
    private def label_height(users : Array(EmbeddedUser)) : Int32
      grid = @config.grid
      return 0 unless grid.show_names?
      LABEL_HEIGHT + (users.any?(&.role) ? ROLE_HEIGHT : 0)
    end
  end
end
