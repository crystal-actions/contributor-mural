require "html"

module ContributorMural
  module SVG
    # Everything a person is named, labelled or grouped by reaches the document
    # through here, so this is where it has to be made safe to put in one.
    #
    # `HTML.escape` handles the markup, and leaves control characters alone —
    # they are legal in HTML. XML allows exactly three of them (tab, newline,
    # carriage return) and no parser will read a document carrying any of the
    # others, so one stray byte in a display name does not garble a label, it
    # costs the whole file: the run still exits 0 and still commits, and the
    # mural renders as nothing at all.
    #
    # Dropped rather than reported, because the name is not always the user's to
    # correct — an API-sourced display name never passes through config
    # validation, which is also why this cannot live there.
    def self.escape(value : String) : String
      HTML.escape(unrepresentable?(value) ? value.delete { |char| forbidden?(char) } : value)
    end

    # Scanned before rewriting so the ordinary string is not copied twice.
    private def self.unrepresentable?(value : String) : Bool
      value.each_char.any? { |char| forbidden?(char) }
    end

    # XML 1.0's `Char` production, minus what cannot appear in a Crystal string:
    # `#x9 | #xA | #xD | [#x20-#xD7FF] | [#xE000-#xFFFD] | [#x10000-#x10FFFF]`.
    private def self.forbidden?(char : Char) : Bool
      code = char.ord
      return true if code < 0x20 && code != 0x09 && code != 0x0A && code != 0x0D
      code == 0xFFFE || code == 0xFFFF
    end

    # Formats a coordinate with at most two decimals and no trailing zeros,
    # keeping output compact and golden files stable.
    def self.num(value : Float64) : String
      formatted = ("%.2f" % value).rstrip('0').rstrip('.')
      formatted.in?("", "-0") ? "0" : formatted
    end

    def self.num(value : Int) : String
      value.to_s
    end

    def self.document(width : Int | Float64, height : Int | Float64,
                      & : String::Builder ->) : String
      String.build do |io|
        io << %(<svg xmlns="http://www.w3.org/2000/svg" width="#{num(width)}" height="#{num(height)}" viewBox="0 0 #{num(width)} #{num(height)}">\n)
        yield io
        io << "</svg>\n"
      end
    end
  end
end
