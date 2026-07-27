require "./spec_helper"

private class Tripwire
  getter peak = 0

  def initialize
    @live = 0
  end

  def enter : Nil
    @live += 1
    @peak = @live if @live > @peak
  end

  def leave : Nil
    @live -= 1
  end
end

describe ContributorMural::Concurrent do
  it "returns results in input order regardless of completion order" do
    items = [5, 1, 4, 2, 3]
    result = ContributorMural::Concurrent.map(items, 4) do |item|
      # The larger the item the later it finishes, so completion order is the
      # reverse of input order for the first window.
      item.times { Fiber.yield }
      item * 10
    end

    result.should eq([50, 10, 40, 20, 30])
  end

  it "keeps at most `limit` jobs in flight" do
    tripwire = Tripwire.new
    ContributorMural::Concurrent.map((1..30).to_a, 4) do |item|
      tripwire.enter
      Fiber.yield
      tripwire.leave
      item
    end

    tripwire.peak.should eq(4)
  end

  it "runs every item even when limit exceeds the work" do
    seen = [] of Int32
    ContributorMural::Concurrent.map([1, 2, 3], 99) { |item| seen << item; item }
    seen.sort.should eq([1, 2, 3])
  end

  it "hands back an exception the block returned as an ordinary value" do
    # The avatar embedder depends on this: a failed fetch travels alongside the
    # successes as data, and must not be mistaken for a raised failure.
    result = ContributorMural::Concurrent.map([1, 2], 2) do |item|
      item == 1 ? "ok".as(String | Exception) : Exception.new("carried").as(String | Exception)
    end

    result[0].should eq("ok")
    result[1].as(Exception).message.should eq("carried")
  end

  it "re-raises the first failure in input order, not the first to happen" do
    # The last item fails immediately, the second fails only after yielding, so
    # whichever error surfaces must be decided by position and not by timing.
    error = expect_raises(Exception, "second") do
      ContributorMural::Concurrent.map([1, 2, 3], 3) do |item|
        case item
        when 2 then Fiber.yield; raise "second"
        when 3 then raise "third"
        else        item
        end
      end
    end
    error.message.should eq("second")
  end

  it "lets every worker finish before the failure surfaces" do
    # A fiber still running after the caller has raised would keep touching
    # state the caller believes it is done with.
    finished = [] of Int32
    expect_raises(Exception, "boom") do
      ContributorMural::Concurrent.map((1..6).to_a, 3) do |item|
        raise "boom" if item == 1
        Fiber.yield
        finished << item
      end
    end

    finished.sort.should eq([2, 3, 4, 5, 6])
  end

  it "raises straight through when there is nothing to overlap" do
    expect_raises(Exception, "alone") do
      ContributorMural::Concurrent.map([1], 4) { |item| raise "alone" if item == 1; item }
    end
  end

  it "handles an empty work list" do
    ContributorMural::Concurrent.map([] of Int32, 4) { |item| item }.should be_empty
  end
end
