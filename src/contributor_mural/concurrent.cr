module ContributorMural
  # Bounded fan-out over a work list, results in input order.
  #
  # Three places in the pipeline wait on the network or on a subprocess with
  # nothing to do in between — avatars, API sources, PNG conversion — and each
  # had (or wanted) its own hand-rolled fiber pool. One helper keeps the
  # failure handling in a single place, which is the part that is easy to get
  # wrong: a fiber that dies takes its result with it, and a collector counting
  # replies then blocks forever.
  module Concurrent
    # A raised exception, boxed. Callers are allowed to *return* an exception as
    # an ordinary value — the avatar embedder does exactly that, keeping each
    # failure alongside the successes — so "the block raised" cannot be inferred
    # from the type of what came back. It has to be marked at the point of
    # rescue. Private, so nothing outside can hand one in and be misread.
    private record Failure, error : Exception

    # Runs `block` for every item with at most `limit` in flight. Exceptions do
    # not escape the worker that raised them; they travel back as values and
    # the first one in *input* order is re-raised here, once every worker has
    # stopped. Nothing is left running against state the caller is about to
    # tear down, and which failure surfaces does not depend on scheduling.
    def self.map(items : Array(T), limit : Int32, &block : T -> U) forall T, U
      slots = Array((U | Failure)?).new(items.size, nil)

      if items.size <= 1 || limit <= 1
        # Nothing to overlap. Run inline so a single job keeps its own stack
        # trace and does not pay for a fiber and two channels.
        items.each_with_index { |item, index| slots[index] = block.call(item) }
      else
        queue = Channel(Int32).new(items.size)
        items.each_index { |index| queue.send(index) }
        queue.close

        workers = Math.min(limit, items.size)
        finished = Channel(Nil).new(workers)
        workers.times do
          spawn do
            while index = queue.receive?
              slots[index] =
                begin
                  block.call(items[index])
                rescue ex : Exception
                  Failure.new(ex)
                end
            end
            finished.send(nil)
          end
        end
        workers.times { finished.receive }
      end

      slots.map do |slot|
        raise slot.error if slot.is_a?(Failure)
        slot.as(U)
      end
    end
  end
end
