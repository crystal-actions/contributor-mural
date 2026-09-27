require "base64"
require "compress/zlib"

module ContributorMural
  # What in a silhouette's image counts as the shape.
  enum Ink
    # `alpha` for an image with a transparent background, otherwise `dark` or
    # `light` — whichever is not the colour of the image's own border.
    Auto
    # Anything opaque, whatever its colour: a logo cut out of a transparent PNG.
    Alpha
    # Dark on light: a black logo on a white JPEG.
    Dark
    # Light on dark: a white logo on a black background.
    Light
  end

  # The lit cells of a traced image, on a `columns` × `rows` lattice. Cells are
  # {column, row} in reading order; the renderer decides the order they fill in.
  struct SilhouetteMask
    getter columns : Int32
    getter rows : Int32
    getter cells : Array({Int32, Int32})

    def initialize(@columns, @rows, @cells)
    end

    # A mask drawn as text, one line per row and `#` for a lit cell — what the
    # specs write instead of an image.
    def self.parse(art : String) : SilhouetteMask
      lines = art.lines.map(&.rstrip).reject(&.empty?)
      cells = [] of {Int32, Int32}
      lines.each_with_index do |line, row|
        line.each_char_with_index { |char, column| cells << {column, row} if char == '#' }
      end
      new(lines.max_of?(&.size) || 0, lines.size, cells)
    end
  end

  # Turns an image file into a `SilhouetteMask`.
  #
  # Crystal has no image decoders, and adding one per format would mean a
  # dependency per format. librsvg already reads all of them — it is the PNG
  # rasterizer this action ships with — so the image is wrapped in a one-element
  # SVG and rendered, and the only thing this has to decode is what comes back:
  # cairo's 8-bit RGBA PNG, which is a zlib stream and five scanline filters.
  #
  # Up to three passes. With `ink: auto` the image is first stretched over the
  # whole canvas to decide what counts as ink: stretched, every transparent
  # pixel is the image's own, where letterboxed it could be the canvas showing
  # through. Then it is fitted into the canvas to find where the shape is, and
  # last just that box is rendered, sized so every cell of the lattice lands on
  # exactly SAMPLES × SAMPLES pixels. A tall, narrow logo is sampled as finely
  # as a square one, and deciding a cell is a plain average rather than an
  # interpolation.
  module SilhouetteTracer
    CANVAS  = 512
    SAMPLES =   8
    # The image travels to librsvg as a base64 data URI in an XML attribute,
    # and libxml2 refuses attribute values past ten million characters. Base64
    # costs a third on top, which puts the real ceiling at 7.5 MB.
    MAX_BYTES = 7 * 1024 * 1024

    PNG_SIGNATURE = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    # A pixel counts toward the shape's bounding box from here, or from
    # `threshold` when that is lower. Half-covered anti-aliasing at the rim
    # should not widen the box by a pixel either side — but a `threshold`
    # lowered to keep a thin stroke has to keep its outer edge in the box too.
    EDGE = 0.5
    # How much of a stretched image may be transparent before it is treated as
    # a cut-out. Anti-aliasing and a stray pixel cost a sliver; a logo on a
    # transparent background leaves whole corners.
    CUTOUT_SHARE = 0.01
    # Ink below this is paper: JPEG noise, a faint tint, anti-aliasing.
    FLOOR = 0.1

    def self.load(workspace : String, config : SilhouetteConfig, rasterizer : Rasterizer) : SilhouetteMask
      path = config.image || raise ConfigError.new("silhouette needs an `image`")
      trace(read(workspace, path), config, rasterizer, path)
    end

    def self.trace(bytes : Bytes, config : SilhouetteConfig, rasterizer : Rasterizer,
                   name : String = "image") : SilhouetteMask
      type = media_type(bytes, name)
      bytes = with_view_box(bytes) if type == "image/svg+xml"
      href = "data:#{type};base64,#{Base64.strict_encode(bytes)}"

      ink = config.ink
      if ink.auto?
        width, height, pixels = decode(rasterizer.rasterize(canvas(href, "none"), 1.0))
        ink = guess_ink(width, height, pixels)
      end

      width, height, pixels = decode(rasterizer.rasterize(canvas(href, "xMidYMid meet"), 1.0))
      gain = gain(pixels, ink)
      box = gain && bounds(width, height, pixels, ink, gain, Math.min(EDGE, config.threshold))
      unless gain && box
        read_as = config.ink.auto? ? " (read as `#{ink.to_s.downcase}`)" : ""
        raise ConfigError.new("silhouette `image` #{name} came out blank — it could not be decoded, " \
                              "or nothing in it counts as ink under `ink: #{config.ink.to_s.downcase}`#{read_as}; " \
                              "try setting `ink` to `alpha`, `dark`, or `light`")
      end

      columns, rows, view = lattice(box, config.resolution)
      width, height, pixels = decode(rasterizer.rasterize(framed(href, columns, rows, view), 1.0))
      unless width == columns * SAMPLES && height == rows * SAMPLES
        raise RasterError.new("tracing #{name} came back #{width}×#{height}, expected " \
                              "#{columns * SAMPLES}×#{rows * SAMPLES}")
      end

      mask = sample(columns, rows, pixels, ink, gain, config.threshold)
      if mask.cells.empty?
        raise ConfigError.new("silhouette `image` #{name} has no cell at least " \
                              "#{(config.threshold * 100).round.to_i}% ink at `resolution: #{config.resolution}` " \
                              "— lower `threshold` or raise `resolution`")
      end
      mask
    end

    # The path was checked for shape at config load. What is left is what only
    # the filesystem can answer — including a symlink out of the repository,
    # which a relative path with no `..` in it can still be.
    private def self.read(workspace : String, path : String) : Bytes
      WorkspaceFile.read(workspace, path, MAX_BYTES)
    rescue ex : WorkspaceFile::Error
      message =
        case ex.failure
        in .missing?    then "not found: #{path} (paths are relative to the repository root)"
        in .escapes?    then "must stay inside the repository: #{path}"
        in .too_large?  then "is larger than #{MAX_BYTES // (1024 * 1024)} MB: #{path}"
        in .unreadable? then "could not be read: #{path} (#{ex.message})"
        end
      raise ConfigError.new("silhouette `image` #{message}")
    end

    # By content rather than by extension: a `.png` that is really a JPEG is
    # common, and librsvg goes by the media type it is told. An SVG can open
    # with any amount of prolog — a licence comment, a DOCTYPE, metadata — so
    # it is looked for anywhere in the file.
    private def self.media_type(bytes : Bytes, name : String) : String
      return "image/png" if bytes.size >= 8 && bytes[0, 8] == PNG_SIGNATURE
      return "image/jpeg" if bytes.size >= 3 && bytes[0, 3] == Bytes[0xFF, 0xD8, 0xFF]
      return "image/gif" if bytes.size >= 6 && bytes[0, 4] == "GIF8".to_slice
      return "image/webp" if bytes.size >= 12 && bytes[0, 4] == "RIFF".to_slice && bytes[8, 4] == "WEBP".to_slice
      return "image/svg+xml" if String.new(bytes).scrub.includes?("<svg")
      raise ConfigError.new("silhouette `image` #{name} is not a PNG, JPEG, GIF, WebP, or SVG")
    end

    # An SVG with a width and height but no viewBox has no aspect ratio for
    # `meet` to keep: librsvg stretches it over the whole canvas instead. Its
    # own width and height are what a viewBox would have said, so say it —
    # when they are plain numbers. A size in other units is left alone.
    private def self.with_view_box(bytes : Bytes) : Bytes
      svg = String.new(bytes)
      return bytes unless svg.valid_encoding?
      tag = svg.match(/<svg\b[^>]*>/m)
      return bytes if tag.nil? || tag[0].matches?(/\sviewBox\s*=/)
      width = dimension(tag[0], "width")
      height = dimension(tag[0], "height")
      return bytes unless width && height

      opened = tag[0].sub(/\A<svg\b/, %(<svg viewBox="0 0 #{width} #{height}"))
      "#{svg[0, tag.begin]}#{opened}#{svg[tag.end..]}".to_slice
    end

    private def self.dimension(tag : String, name : String) : String?
      match = tag.match(/\s#{name}\s*=\s*["']\s*([0-9]*\.?[0-9]+)\s*(?:px)?\s*["']/)
      return unless match
      value = match[1]
      value.to_f64 > 0 ? value : nil
    end

    private def self.canvas(href : String, fit : String) : String
      %(<svg xmlns="http://www.w3.org/2000/svg" width="#{CANVAS}" height="#{CANVAS}" viewBox="0 0 #{CANVAS} #{CANVAS}">) +
        image(href, fit) + "</svg>"
    end

    # The same image, cropped to `view` (in canvas units) and stretched over
    # the lattice. `view` already has the lattice's aspect ratio, so `none`
    # only rules out a sub-pixel letterbox from rounding.
    private def self.framed(href : String, columns : Int32, rows : Int32,
                            view : {Float64, Float64, Float64, Float64}) : String
      x, y, w, h = view
      %(<svg xmlns="http://www.w3.org/2000/svg" width="#{columns * SAMPLES}" height="#{rows * SAMPLES}" ) +
        %(viewBox="#{coordinate(x)} #{coordinate(y)} #{coordinate(w)} #{coordinate(h)}" preserveAspectRatio="none">) +
        image(href, "xMidYMid meet") + "</svg>"
    end

    private def self.image(href : String, fit : String) : String
      %(<image href="#{href}" width="#{CANVAS}" height="#{CANVAS}" preserveAspectRatio="#{fit}"/>)
    end

    # More precision than `SVG.num`: the last pass is only exact when the crop
    # lines up with the one before it to well under a sample.
    private def self.coordinate(value : Float64) : String
      formatted = ("%.4f" % value).rstrip('0').rstrip('.')
      formatted.in?("", "-0") ? "0" : formatted
    end

    # Read off the image stretched over the canvas, so there is no letterbox:
    # any real transparency is the image's own, and a cut-out is traced by its
    # alpha. An opaque image is traced by whichever way of reading it leaves
    # its own border as paper.
    private def self.guess_ink(width : Int32, height : Int32, pixels : Bytes) : Ink
      holes = (width * height).times.count { |index| pixels[index * 4 + 3] < 128 }
      return Ink::Alpha if holes > width * height * CUTOUT_SHARE

      rim = [] of Float64
      width.times { |x| rim << luminance(pixels, x) << luminance(pixels, (height - 1) * width + x) }
      height.times { |y| rim << luminance(pixels, y * width) << luminance(pixels, y * width + width - 1) }
      rim.sum / rim.size < 0.5 ? Ink::Light : Ink::Dark
    end

    # What the strongest ink in the image is multiplied by to read as full
    # ink, or nil when there is none. A black logo needs nothing; an orange
    # one on white is only 0.4 dark, which a fixed cut at a half would throw
    # away entirely. The strongest is taken as a high percentile rather than
    # the maximum, so one dark speck cannot set the scale for a pale logo.
    private def self.gain(pixels : Bytes, ink : Ink) : Float64?
      histogram = Array.new(256, 0)
      (pixels.size // 4).times do |index|
        histogram[(ink_at(pixels, index, ink, 1.0) * 255).round.to_i] += 1
      end
      floor = (FLOOR * 255).ceil.to_i
      inked = histogram[floor..].sum
      return if inked.zero?

      remaining = inked * 0.02
      level = 255
      while level > floor && (remaining -= histogram[level]) > 0
        level -= 1
      end
      255.0 / level
    end

    # {x0, y0, x1, y1}, exclusive at the far edge, or nil when nothing is ink.
    private def self.bounds(width : Int32, height : Int32, pixels : Bytes, ink : Ink,
                            gain : Float64, edge : Float64) : {Int32, Int32, Int32, Int32}?
      x0, y0, x1, y1 = width, height, 0, 0
      height.times do |y|
        width.times do |x|
          next if ink_at(pixels, y * width + x, ink, gain) < edge
          x0 = x if x < x0
          x1 = x + 1 if x >= x1
          y0 = y if y < y0
          y1 = y + 1 if y >= y1
        end
      end
      x1 > x0 ? {x0, y0, x1, y1} : nil
    end

    # `resolution` cells along the box's longer side, the shorter side rounded
    # to whole cells, and the crop that gives exactly that lattice — centred on
    # the box, so the rounding spills evenly off both ends.
    private def self.lattice(box : {Int32, Int32, Int32, Int32},
                             resolution : Int32) : {Int32, Int32, {Float64, Float64, Float64, Float64}}
      x0, y0, x1, y1 = box
      width = (x1 - x0).to_f
      height = (y1 - y0).to_f
      cell = Math.max(width, height) / resolution
      columns = Math.max((width / cell).round.to_i, 1)
      rows = Math.max((height / cell).round.to_i, 1)
      view_width = columns * cell
      view_height = rows * cell
      {columns, rows, {x0 + (width - view_width) / 2, y0 + (height - view_height) / 2, view_width, view_height}}
    end

    # A cell is lit when its SAMPLES × SAMPLES pixels average at least
    # `threshold` ink. Rows and columns left empty at the edges are trimmed:
    # the box was found at canvas resolution, so a rim that fell below the
    # threshold at lattice resolution would otherwise pad one side.
    private def self.sample(columns : Int32, rows : Int32, pixels : Bytes,
                            ink : Ink, gain : Float64, threshold : Float64) : SilhouetteMask
      width = columns * SAMPLES
      lit = [] of {Int32, Int32}
      rows.times do |row|
        columns.times do |column|
          total = 0.0
          SAMPLES.times do |line|
            base = (row * SAMPLES + line) * width + column * SAMPLES
            SAMPLES.times { |offset| total += ink_at(pixels, base + offset, ink, gain) }
          end
          lit << {column, row} if total / (SAMPLES * SAMPLES) >= threshold
        end
      end
      return SilhouetteMask.new(0, 0, lit) if lit.empty?

      left = lit.min_of(&.[0])
      top = lit.min_of(&.[1])
      SilhouetteMask.new(lit.max_of(&.[0]) - left + 1, lit.max_of(&.[1]) - top + 1,
        lit.map { |(column, row)| {column - left, row - top} })
    end

    # How much pixel `index` is shape, in [0, 1], after `gain`. `dark`
    # composites over white and `light` over black, which is what makes the
    # transparent letterbox count as paper in both.
    private def self.ink_at(pixels : Bytes, index : Int32, ink : Ink, gain : Float64) : Float64
      alpha = pixels[index * 4 + 3] / 255.0
      raw =
        case ink
        in .alpha? then alpha
        in .dark?  then alpha * (1.0 - luminance(pixels, index))
        in .light? then alpha * luminance(pixels, index)
        in .auto?  then raise ArgumentError.new("ink must be resolved before sampling")
        end
      Math.min(raw * gain, 1.0)
    end

    private def self.luminance(pixels : Bytes, index : Int32) : Float64
      offset = index * 4
      (0.2126 * pixels[offset] + 0.7152 * pixels[offset + 1] + 0.0722 * pixels[offset + 2]) / 255.0
    end

    # {width, height, RGBA bytes}. Only as much PNG as librsvg writes: 8-bit
    # RGBA or RGB, not interlaced. RGB is widened to opaque RGBA.
    def self.decode(png : Bytes) : {Int32, Int32, Bytes}
      header, compressed = chunks(png)
      width, height, channels = dimensions(header)
      raw = Compress::Zlib::Reader.open(IO::Memory.new(compressed), &.getb_to_end)
      stride = width * channels
      raise RasterError.new("tracing produced a truncated PNG") if raw.size < (stride + 1) * height

      rows = unfilter(raw, stride, height, channels)
      return {width, height, rows} if channels == 4

      rgba = Bytes.new(width * height * 4, 255_u8)
      (width * height).times do |index|
        3.times { |channel| rgba[index * 4 + channel] = rows[index * 3 + channel] }
      end
      {width, height, rgba}
    rescue ex : IO::Error | IndexError | OverflowError | Compress::Deflate::Error | Compress::Zlib::Error
      raise RasterError.new("tracing produced a PNG that could not be read: #{ex.message}")
    end

    # {IHDR payload, every IDAT payload joined in order}. The other chunks —
    # gamma, text, physical size — say nothing about which pixels are ink.
    private def self.chunks(png : Bytes) : {Bytes, Bytes}
      unless png.size >= 8 && png[0, 8] == PNG_SIGNATURE
        raise RasterError.new("tracing produced something that is not a PNG")
      end
      io = IO::Memory.new(png[8..])
      header = nil
      compressed = IO::Memory.new
      loop do
        length = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
        type = io.read_string(4)
        data = Bytes.new(length)
        io.read_fully(data)
        io.skip(4) # CRC
        case type
        when "IHDR" then header = data
        when "IDAT" then compressed.write(data)
        when "IEND" then break
        end
      end
      {header || raise(RasterError.new("tracing produced a PNG with no image header")), compressed.to_slice}
    end

    # {width, height, channels} out of IHDR, refusing what `unfilter` cannot
    # take apart.
    private def self.dimensions(header : Bytes) : {Int32, Int32, Int32}
      width = IO::ByteFormat::BigEndian.decode(UInt32, header[0, 4]).to_i
      height = IO::ByteFormat::BigEndian.decode(UInt32, header[4, 4]).to_i
      channels = {6 => 4, 2 => 3}[header[9]]? || 0
      unless header[8] == 8 && channels > 0 && header[12] == 0
        raise RasterError.new("tracing produced a PNG this cannot read " \
                              "(depth #{header[8]}, colour type #{header[9]}, interlace #{header[12]})")
      end
      raise RasterError.new("tracing produced an empty PNG") if width.zero? || height.zero?
      {width, height, channels}
    end

    # Reverses the per-scanline filters (PNG spec §9): each byte was stored as
    # its difference from a prediction off its left, upper, and upper-left
    # neighbours.
    private def self.unfilter(raw : Bytes, stride : Int32, height : Int32, bpp : Int32) : Bytes
      result = Bytes.new(stride * height)
      height.times do |y|
        filter = raw[y * (stride + 1)]
        source = y * (stride + 1) + 1
        target = y * stride
        stride.times do |x|
          left = x >= bpp ? result[target + x - bpp].to_i : 0
          up = y > 0 ? result[target - stride + x].to_i : 0
          corner = x >= bpp && y > 0 ? result[target - stride + x - bpp].to_i : 0
          prediction =
            case filter
            when 0 then 0
            when 1 then left
            when 2 then up
            when 3 then (left + up) // 2
            when 4 then paeth(left, up, corner)
            else        raise RasterError.new("tracing produced a PNG with an unknown filter #{filter}")
            end
          result[target + x] = ((raw[source + x].to_i + prediction) & 0xFF).to_u8
        end
      end
      result
    end

    private def self.paeth(left : Int32, up : Int32, corner : Int32) : Int32
      estimate = left + up - corner
      to_left = (estimate - left).abs
      to_up = (estimate - up).abs
      to_corner = (estimate - corner).abs
      return left if to_left <= to_up && to_left <= to_corner
      to_up <= to_corner ? up : corner
    end
  end
end
