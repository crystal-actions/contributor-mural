module ContributorMural::Renderers
  # A pile of stones: everyone is a disc sized by their rank, poured into a slab
  # and shaken until nothing overlaps. The only style that does not fill its
  # rectangle — the page shows between the pebbles, which means it themes itself
  # for free the way voronoi's lead does.
  #
  # The pack is a relaxation rather than a formula. Discs start on a jittered
  # lattice across the slab, and then every sweep pushes overlapping pairs
  # apart, carries the whole pile a step toward the slab it is aimed at, and
  # holds it inside. `width` caps how wide the slab may be and `density` says
  # how much of it the pebbles cover; between them they decide how tall the
  # pile comes out.
  class Pebble < Renderer
    # One clip for the whole document: the image box is exactly the disc's
    # bounding square, so the unit circle is the pebble.
    CLIP_ID = "pebble-clip"

    # Sweeps of separate-fit-hold, then a tail that only separates and holds.
    # The tail is what makes "no two pebbles overlap" true rather than nearly
    # true: the fit runs after the separation in every sweep, so the last thing
    # to happen to the pack would otherwise be a squeeze that can push a pair
    # back together. It leaves as soon as a sweep finds nothing worth moving,
    # so its cap is a backstop rather than a cost.
    RELAX_STEPS  =  260
    SETTLE_STEPS = 1000

    # How much of the way toward the slab each sweep carries the pack. Small
    # enough that the separation keeps up with the stretch, large enough to
    # arrive well inside the sweep budget.
    FIT_RATE = 0.08

    # How wide the pile wants to be against how tall, before `width` caps it.
    # A mural sits above or below a README's prose, so it wants to be a band;
    # much past this and a small crowd reads as a scattered line rather than a
    # pile.
    TARGET_ASPECT = 2.4

    # How much the slab grows, and how many times, when the pack cannot settle
    # inside the one it was given.
    #
    # A `density` is a request, and whether it can be met depends on the crowd:
    # the same figure that packs cleanly at forty people jams at eight, where
    # there are too few discs for the edges not to dominate. Rather than pick
    # the one figure that survives every crowd — which would be well below what
    # looks good for the crowds people actually have — the pack loosens and
    # tries again. Six goes at eight percent give the slab half again the room,
    # enough to carry the tightest density the config allows down to where it
    # settles, so "no two pebbles overlap" holds for every config rather than
    # for the ones that happened to get tested.
    EASE       = 1.08
    EASE_TRIES =    6

    # Breathing room around the finished pile, so a pebble on the edge is not
    # flush against the document bounds.
    PAD = 2.0

    # Two centres this close have no direction to be pushed along.
    TOUCHING = 1e-9

    # An overlap smaller than this is left alone, and a sweep that found nothing
    # bigger counts as having settled. Without a floor the pack never stops:
    # every sweep finds a pair a few millionths of a pixel inside its clearance,
    # pushes it out, and nudges two more in — so the settle runs to its cap
    # every time and the whole style comes out orders of magnitude slower than
    # the rest. Coordinates are written to two decimals, so this is three
    # decimals below anything a reader could see.
    RESOLVED = 1e-3

    # Disc-sweeps a section may spend before the sweep count gives way. Reached
    # at about three thousand people; below that the step count is fixed.
    RELAX_BUDGET = 800_000
    MIN_STEPS    =      60

    # Voronoi's salt multiplier, in the same role: keeps one section's jitter
    # from repeating in the next.
    SALT_JITTER = 104729_u64

    private record Disc, x : Float64, y : Float64, r : Float64

    @sizes = {} of String => Float64
    # Packed sections, keyed by the logins they hold. The base class sizes
    # every section before drawing any of them, and there is no closed form for
    # the block — it is the bounding box the relaxation happens to land on — so
    # the pack has to survive between the two calls.
    @layouts = {} of String => Array(Disc)

    # Dense rank over the *distinct* weights, as voronoi does, so a contributor
    # with 1000x the commits lands at the top of the taper exactly like one with
    # 2x. Where voronoi leaves the table empty for an all-equal crowd, this
    # fills it at full size: a rank of zero would read as "smallest pebble",
    # and no ranking information should mean a uniform field, not a field of
    # minimums.
    def prepare(users : Array(ResolvedUser)) : Nil
      pebble = @config.pebble
      distinct = users.map(&.weight).uniq!.sort!
      if distinct.size <= 1
        users.each { |user| @sizes[user.login] = pebble.max_size.to_f * user.scale }
        return
      end

      ratio = pebble.min_size.to_f / pebble.max_size
      span = (distinct.size - 1).to_f
      positions = {} of Int32 => Float64
      distinct.each_with_index { |weight, index| positions[weight] = index / span }
      users.each do |user|
        rank = positions[user.weight]
        @sizes[user.login] = (ratio + (1.0 - ratio) * rank) * pebble.max_size * user.scale
      end
    end

    # The image box is exactly the drawn diameter and the clip is inscribed in
    # it, so unlike voronoi — where a heavy cell runs wider than its nominal
    # pitch — nothing here outgrows the size it was fetched for. Plain 2x for
    # high-DPI is exact.
    def fetch_size(user : ResolvedUser) : Int32
      (size_for(user.login, user.scale) * 2).ceil.to_i
    end

    # The jitter is salted by the section's ordinal, which the memo hands out.
    protected def reset_document : Nil
      @layouts.clear
    end

    protected def defs(io : String::Builder) : Nil
      shape_clip(io, CLIP_ID, Shape::Circle)
    end

    protected def block_size(users : Array(EmbeddedUser)) : {Float64, Float64}
      return {16.0, 16.0} if users.empty?

      discs = layout(users)
      {discs.max_of { |disc| disc.x + disc.r } + PAD, discs.max_of { |disc| disc.y + disc.r } + PAD}
    end

    protected def draw_block(io : String::Builder, users : Array(EmbeddedUser), y_offset : Float64) : Nil
      return if users.empty?

      # Drawn in list order, so whatever `sort` asked for still comes out in the
      # document — the shuffle `seed` does is over lattice cells, not over
      # people, and never reaches this far.
      discs = layout(users)
      users.each_with_index do |user, index|
        disc = discs[index]
        side = disc.r * 2
        linked(io, user) do
          avatar(io, user, disc.x - disc.r, disc.y - disc.r + y_offset, side, side, CLIP_ID)
        end
      end
    end

    # `pack` is a pure function of its arguments, so this cache only saves the
    # second run — dropping it would draw the same document. Keying on the
    # logins rather than counting calls is what keeps it honest: a user carries
    # exactly one group, so two sections can never present the same list, and a
    # memo keyed on its own inputs cannot drift out of step the way two
    # counters incremented in two different methods can.
    private def layout(users : Array(EmbeddedUser)) : Array(Disc)
      key = users.join('\n', &.login)
      @layouts[key]? || (@layouts[key] = pack(users, @layouts.size))
    end

    private def pack(users : Array(EmbeddedUser), ordinal : Int32) : Array(Disc)
      radii = users.map { |user| size_for(user.login, user.scale) / 2 }
      salt = ordinal.to_u64 &* SALT_JITTER
      # The sweep line's scratch, allocated once for the whole pack rather than
      # once per sweep: at a few thousand sweeps that allocation is most of the
      # render.
      line = Line.new(radii, @config.pebble.gap)

      xs = Array(Float64).new
      ys = Array(Float64).new
      ease = 1.0
      EASE_TRIES.times do
        width, height = slab(radii, ease)
        xs, ys = seed(radii, width, height, salt)
        relax(xs, ys, radii, width, height, line)
        break if settle(xs, ys, radii, width, height, line)
        ease *= EASE
      end

      left = (0...radii.size).min_of { |index| xs[index] - radii[index] }
      top = (0...radii.size).min_of { |index| ys[index] - radii[index] }
      radii.map_with_index do |radius, index|
        Disc.new(xs[index] - left + PAD, ys[index] - top + PAD, radius)
      end
    end

    # The slab the pack is fitted to, sized by the crowd rather than fixed.
    #
    # What a pebble claims is its disc plus half the clearance all round, so
    # that is the area that has to fit; `density` says how much of the slab
    # that claimed area covers, which is the difference between a tight pile
    # and an airy one. Left to itself the slab comes out at `TARGET_ASPECT`,
    # and `width` is a cap rather than a target — a handful of people make a
    # small pile instead of a sparse line stretched across the full width, and
    # a crowd large enough to hit the cap grows downward instead.
    private def slab(radii : Array(Float64), ease : Float64) : {Float64, Float64}
      pebble = @config.pebble
      claimed = radii.sum do |radius|
        reach = radius + pebble.gap / 2.0
        Math::PI * reach * reach
      end
      area = claimed * ease / pebble.density
      # A pile cannot be narrower than the widest stone in it, so a cap that
      # cannot hold one pebble is void and the slab falls back to its natural
      # shape. Only `scale` can get there — `width` is validated against
      # `max_size`, but a 1.6x on top of that is not — and holding the cap
      # anyway would pin the slab at one pebble wide and stack the whole crowd
      # into a single column several thousand pixels tall.
      floor = 2 * radii.max
      natural = Math.sqrt(area * TARGET_ASPECT)
      cap = pebble.width.to_f
      width = floor > cap ? Math.max(natural, floor) : Math.max(Math.min(cap, natural), floor)
      {width, Math.max(area / width, floor)}
    end

    # A jittered lattice across the whole slab, one cell per person, shuffled so
    # the big pebbles and the small ones start mixed.
    #
    # The obvious seeding for a pack is a golden-angle spiral, and it is wrong
    # here: a spiral fills a disc, so the pile comes out a lens floating in its
    # own bounding box with four empty corners, and the corners survive
    # everything the relaxation does afterwards — separation only pushes people
    # apart and has no reason to send anyone into a corner nobody is near. A
    # lattice starts rectangular and stays rectangular.
    #
    # The shuffle is what keeps it from banding: the list arrives sorted by
    # weight, so laying it out in order would put every large pebble in the top
    # rows and every small one along the bottom.
    private def seed(radii : Array(Float64), width : Float64, height : Float64,
                     salt : UInt64) : {Array(Float64), Array(Float64)}
      count = radii.size
      columns = Math.max(1, Math.sqrt(count * width / height).round.to_i)
      rows = (count + columns - 1) // columns
      cell_w = width / columns
      cell_h = height / rows
      jitter = @config.pebble.jitter
      slots = shuffled(count, salt)

      xs = Array.new(count, 0.0)
      ys = Array.new(count, 0.0)
      count.times do |index|
        slot = slots[index]
        column = slot % columns
        row = slot // columns
        xs[index] = (column + 0.5) * cell_w + (noise(index * 2, salt) - 0.5) * jitter * cell_w
        ys[index] = (row + 0.5) * cell_h + (noise(index * 2 + 1, salt) - 0.5) * jitter * cell_h
      end

      {xs, ys}
    end

    # Fisher-Yates off the shared noise rather than off a generator, so the
    # shuffle is the same on every run and on every platform. `noise` lands in
    # [0, 1) exactly — the divisor is a power of two — so the draw is always a
    # legal index.
    private def shuffled(count : Int32, salt : UInt64) : Array(Int32)
      slots = (0...count).to_a
      (count - 1).downto(1) do |index|
        slots.swap(index, (noise(index, salt &+ 1_u64) * (index + 1)).to_i)
      end
      slots
    end

    # Separate, then carry the pack a step toward the slab, then hold it inside.
    #
    # The step is a scaling rather than a pull toward a point, and that is the
    # whole of it: a point attractor has no idea when to stop, so it goes on
    # compressing a pile that already fits until the middle of it is jammed
    # solid and no amount of separating can prise it apart again. Measuring the
    # pack against the slab each sweep gives the stretch somewhere to arrive.
    private def relax(xs : Array(Float64), ys : Array(Float64), radii : Array(Float64),
                      width : Float64, height : Float64, line : Line) : Nil
      steps_for(radii.size).times do
        separate(xs, ys, radii, line)
        fit(xs, radii, width)
        fit(ys, radii, height)
        radii.size.times do |index|
          xs[index] = hold(xs[index], radii[index], width)
          ys[index] = hold(ys[index], radii[index], height)
        end
      end
    end

    # One axis, a fraction of the way from the extent it has to the extent it
    # wants, about its own middle. Stretching can never make two pebbles
    # overlap, and squeezing only ever makes work the next sweep undoes.
    private def fit(values : Array(Float64), radii : Array(Float64), target : Float64) : Nil
      low = (0...radii.size).min_of { |index| values[index] - radii[index] }
      high = (0...radii.size).max_of { |index| values[index] + radii[index] }
      extent = high - low
      return if extent < TOUCHING

      middle = (low + high) / 2
      scale = 1.0 + (target / extent - 1.0) * FIT_RATE
      values.size.times { |index| values[index] = middle + (values[index] - middle) * scale }
    end

    # A pebble wider than the slab is left where it is rather than held.
    # `width` is validated against `max_size`, so this is only reachable through
    # a `scale` that pushes one past the cap — and then pinning it to the middle
    # would pin *every* pebble that size to the same middle, leaving them able
    # to separate only downward. A wall of ten emphasised avatars came out one
    # per row and eight times taller than it needed to be.
    private def hold(x : Float64, radius : Float64, width : Float64) : Float64
      return x if width - radius <= radius
      x.clamp(radius, width - radius)
    end

    # Separation with the walls still up but the gravity off, so the run ends on
    # a sweep that made the pack legal rather than on one that squeezed it
    # again. The walls stay because they are the whole meaning of `width`: let
    # go of them here and a pack that jammed during the gathering springs out
    # sideways, and the document comes back half again as wide as it was asked
    # for. `density` is bounded below what a relaxed pack of mixed discs
    # actually reaches, so there is room to separate inside the slab.
    # Returns whether the pack came to rest, which is what tells `pack` the slab
    # was big enough to hold it.
    private def settle(xs : Array(Float64), ys : Array(Float64), radii : Array(Float64),
                       width : Float64, height : Float64, line : Line) : Bool
      # Walls first, separation second, and the loop leaves on a separation that
      # found nothing to do — so the pack it stops on is both inside the slab
      # and legal. The other order leaves whatever the last clamp pushed back
      # together, which is an overlap nobody ever comes back to fix.
      SETTLE_STEPS.times do
        radii.size.times do |index|
          xs[index] = hold(xs[index], radii[index], width)
          ys[index] = hold(ys[index], radii[index], height)
        end
        return true unless separate(xs, ys, radii, line)
      end
      false
    end

    # One Gauss-Seidel sweep: every overlapping pair is pushed apart by half the
    # overlap each, and later pairs see the earlier moves. Returns whether
    # anything moved, which is what lets `settle` stop early.
    #
    # Pairs come off a sweep line ordered by y rather than out of a double loop
    # over everyone. A wall of a thousand people spends thousands of sweeps
    # settling, and testing half a million pairs in each of them put this style
    # two orders of magnitude behind every other one.
    private def separate(xs : Array(Float64), ys : Array(Float64), radii : Array(Float64),
                         line : Line) : Bool
      moved = false
      gap = @config.pebble.gap
      count = radii.size
      line.rebuild(ys)
      order, snapshot, span = line.order, line.snapshot, line.span

      (0...count).each do |a|
        i = order[a]
        ((a + 1)...count).each do |b|
          # The snapshot is this sweep's starting y, so the cutoff has to allow
          # for what the sweep has moved since. `span` carries that slack.
          break if snapshot[b] - snapshot[a] > span

          j = order[b]
          dx = xs[j] - xs[i]
          dy = ys[j] - ys[i]
          want = radii[i] + radii[j] + gap
          squared = dx * dx + dy * dy
          next if squared >= want * want

          distance = Math.sqrt(squared)
          next if want - distance < RESOLVED

          if distance < TOUCHING
            # Exactly coincident centres: split along x, so even this comes out
            # the same on every run.
            push_x = want / 2
            push_y = 0.0
          else
            push = (want - distance) / distance / 2
            push_x = dx * push
            push_y = dy * push
          end
          xs[i] -= push_x
          ys[i] -= push_y
          xs[j] += push_x
          ys[j] += push_y
          moved = true
        end
      end
      moved
    end

    # A sweep costs about the head count once the sweep line is doing its job,
    # so this only bites for a wall of several thousand — and then it trades
    # sweeps for people rather than letting the render time run away. A
    # deterministic function of the head count, so the pack stays reproducible.
    private def steps_for(count : Int32) : Int32
      return RELAX_STEPS if count * RELAX_STEPS <= RELAX_BUDGET
      Math.max(RELAX_BUDGET // Math.max(count, 1), MIN_STEPS)
    end

    # Scratch for the sweep line: the discs in y order, their y at the start of
    # the sweep, and how far down that order a pair can still be close enough to
    # touch. Two discs can only meet when their centres are within the largest
    # possible clearance, and the slack on top of that is what covers the drift
    # from the moves this sweep has already made.
    private class Line
      getter order : Array(Int32)
      getter snapshot : Array(Float64)
      getter span : Float64

      def initialize(radii : Array(Float64), gap : Int32)
        @order = (0...radii.size).to_a
        @snapshot = Array.new(radii.size, 0.0)
        @span = 3 * (2 * (radii.max? || 0.0) + gap)
      end

      # Ties break on the index, so the order is total and the sweep is the same
      # on every run.
      def rebuild(ys : Array(Float64)) : Nil
        @order.sort! { |a, b| ys[a] == ys[b] ? a <=> b : (ys[a] <=> ys[b]) }
        @order.each_with_index { |index, slot| @snapshot[slot] = ys[index] }
      end
    end

    # `prepare` fills the table; the fallback is for a renderer used without it.
    private def size_for(login : String, scale : Float64) : Float64
      @sizes[login]? || @config.pebble.max_size.to_f * scale
    end
  end
end
