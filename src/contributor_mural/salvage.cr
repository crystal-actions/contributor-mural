module ContributorMural
  # The faces already on the wall, taken back off the file this run is about to
  # replace.
  #
  # An avatar host that throttles, blips, or answers 404 for a minute takes
  # people off the mural, and the run then commits that — so the picture
  # regresses over a failure which has usually fixed itself by the time anyone
  # looks at it. Retrying is not the answer here; the retries already happened
  # and the fetcher gave up.
  #
  # The previous output is the cache. Every avatar in it is base64 in the
  # document, inside the link of the person it belongs to, so a wall that has
  # been rendered once already holds everything needed to redraw it. Nothing
  # extra is written, nothing has to be restored between runs, and a face is
  # only ever reused for someone this run has already decided belongs on the
  # wall — a person dropped by `exclude` or `limit` is never read back in.
  module AvatarSalvage
    LINK_OPEN = %(<a href=")
    # Narrower than `href="data:` on purpose: the only data URI this program
    # emits is an image, and anything else under that prefix is not ours.
    DATA_OPEN = %(href="data:image/)
    HREF_OPEN = %(href=")
    QUOTE     = '"'
    # A face drawn in more than one section is written once into <defs> and
    # referenced from each of them, so for those people the link holds a
    # reference rather than the bytes.
    SYMBOL_OPEN  = %(<symbol id=")
    SYMBOL_CLOSE = "</symbol>"
    USE_OPEN     = %(<use href="#)

    # A data URI longer than this is not one we wrote — the fetcher caps a
    # single avatar at 8 MB before it is base64-encoded.
    MAX_URI = 12 * 1024 * 1024

    # Exactly the shape `Embedder#fetch_missing` builds, and nothing else.
    #
    # What comes back from here is written into an `href` attribute verbatim,
    # the way a freshly encoded one is — which is safe only because base64 and
    # a known content type cannot carry `&`, `<` or a quote. A previous wall is
    # a file on disk, though: hand-edited, merge-mangled, or left half-written
    # by a killed job, it can hold anything between those two quotes, and one
    # bare `&` costs the whole document rather than one label. Salvage is a new
    # route into the markup, so it is checked at the door instead of trusted
    # for having been ours once.
    VALID_URI = /\Adata:image\/[a-z0-9.+-]+;base64,[A-Za-z0-9+\/=]*\z/

    # Link (as it appears in the markup) => data URI, for every person the
    # given outputs already carry.
    def self.read(workspace : String, paths : Array(String)) : Hash(String, String)
      found = {} of String => String
      paths.each do |path|
        # SVG only: a PNG has been rasterized, and the avatars in it stopped
        # being addressable the moment they became pixels.
        next unless path.ends_with?(".svg")
        full = File.join(workspace, path)
        next unless File.file?(full)
        begin
          scan(File.read(full), found)
        rescue IO::Error
          # An unreadable previous wall is a cache miss, not a failure: the run
          # is about to write over it either way.
          next
        end
      end
      found
    end

    # `<a href="LINK" …>` … `<image href="data:image/…;base64,…"`. Every style
    # wraps one person in one link and draws their avatar inside it, so the
    # first data URI after a link belongs to that link, and a link carrying
    # none before the next one contributes nothing.
    #
    # Unless the face is a shared one, in which case the link holds a `<use>`
    # and the bytes sit in a <symbol> further up. Nobody is missing there — the
    # avatar is in the document, just not in this block — so the reference is
    # followed rather than treated as a link with no face.
    #
    # Scanned by byte offset rather than by character: a single non-ASCII
    # display name anywhere in the document turns character indexing into a
    # walk from the start of the string, once per lookup, over a file that is
    # mostly megabytes of base64.
    private def self.scan(svg : String, found : Hash(String, String)) : Nil
      shared = shared_faces(svg)
      cursor = 0
      while open = svg.byte_index(LINK_OPEN, cursor)
        link_start = open + LINK_OPEN.bytesize
        link_end = svg.byte_index(QUOTE, link_start)
        break unless link_end
        cursor = link_end + 1

        # Bounded by the next link so a person whose avatar is missing from the
        # old file cannot adopt the next person's face.
        stop = svg.byte_index(LINK_OPEN, cursor) || svg.bytesize
        link = svg.byte_slice(link_start, link_end - link_start)

        # First one wins, the way the first output listed is the one whose
        # dimensions get reported: several targets hold the same faces at
        # different sizes, and reading them all would only overwrite each
        # entry with its own twin.
        if inline = inline_uri(svg, cursor, stop)
          uri, cursor = inline
          found[link] ||= uri if uri.matches?(VALID_URI)
        elsif uri = referenced_uri(svg, cursor, stop, shared)
          found[link] ||= uri
        end
      end
    end

    # The first `href="data:image/…"` between `cursor` and `stop`, with the
    # offset to carry on from. Shared by the two shapes a face is written in,
    # since a <symbol> holds exactly the <image> a link used to hold.
    private def self.inline_uri(svg : String, cursor : Int32, stop : Int32) : {String, Int32}?
      data = svg.byte_index(DATA_OPEN, cursor)
      return unless data && data < stop

      uri_start = data + HREF_OPEN.bytesize
      uri_end = svg.byte_index(QUOTE, uri_start)
      return unless uri_end && uri_end - uri_start <= MAX_URI
      {svg.byte_slice(uri_start, uri_end - uri_start), uri_end + 1}
    end

    # `<symbol id="ID" …><image href="data:image/…">` — what `Renderer` writes
    # for a face more than one section draws. Collected in one pass up front:
    # the symbols live in the document's <defs>, ahead of every link that could
    # refer to one.
    private def self.shared_faces(svg : String) : Hash(String, String)
      faces = {} of String => String
      cursor = 0
      while open = svg.byte_index(SYMBOL_OPEN, cursor)
        id_start = open + SYMBOL_OPEN.bytesize
        id_end = svg.byte_index(QUOTE, id_start)
        break unless id_end
        cursor = id_end + 1

        stop = svg.byte_index(SYMBOL_CLOSE, cursor) || svg.bytesize
        next unless inline = inline_uri(svg, cursor, stop)
        uri, cursor = inline
        next unless uri.matches?(VALID_URI)
        faces[svg.byte_slice(id_start, id_end - id_start)] = uri
      end
      faces
    end

    # The face a link points at through `<use href="#ID">`, bounded by the next
    # link the same way the inline lookup is.
    private def self.referenced_uri(svg : String, cursor : Int32, stop : Int32,
                                    shared : Hash(String, String)) : String?
      return if shared.empty?
      use = svg.byte_index(USE_OPEN, cursor)
      return unless use && use < stop

      id_start = use + USE_OPEN.bytesize
      id_end = svg.byte_index(QUOTE, id_start)
      return unless id_end
      shared[svg.byte_slice(id_start, id_end - id_start)]?
    end
  end
end
