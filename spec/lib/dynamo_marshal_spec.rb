require "rails_helper"

RSpec.describe Bassinet::Dynamo::Marshal do
  describe ".to_attr / .from_attr round trip" do
    subject(:marshaller) { described_class }

    it "round-trips every supported scalar type" do
      {
        "string" => "hello",
        "integer" => 42,
        "float" => 1.5,
        "true" => true,
        "false" => false
      }.each do |label, value|
        attr = marshaller.to_attr(value)
        expect(marshaller.from_attr(attr)).to eq(value), "#{label} failed"
      end
    end

    it "round-trips nested structures" do
      value = {
        "foods" => ["banana", "oats"],
        "meta" => { "left" => 60, "right" => 45 }
      }
      expect(marshaller.from_attr(marshaller.to_attr(value))).to eq(value)
    end

    it "round-trips an explicit NULL (nil is dropped from maps, kept as an attr)" do
      # A map entry with a nil value is dropped by to_item — that is deliberate.
      # An explicit NULL only survives when it is the value being marshalled
      # directly, which is how `from_attr` reports a genuinely absent attribute.
      expect(marshaller.from_attr(marshaller.to_attr(nil))).to be_nil
      expect(marshaller.from_item(marshaller.to_item("a" => nil))).to eq({})
    end

    it "round-trips negative numbers" do
      expect(marshaller.from_attr(marshaller.to_attr(-7))).to eq(-7)
    end

    it "distinguishes integers from floats" do
      int = marshaller.from_attr(marshaller.to_attr(3))
      float = marshaller.from_attr(marshaller.to_attr(3.0))

      expect(int).to be_a(Integer)
      expect(float).to be_a(Float)
      expect(float).to eq(3.0)
    end

    it "rejects unsupported types loudly" do
      expect { marshaller.to_attr(Object.new) }.to raise_error(ArgumentError)
    end
  end

  describe ".to_item" do
    it "drops nil values so they cannot become explicit NULLs" do
      item = described_class.to_item("a" => 1, "b" => nil, "c" => "x")
      expect(item.keys).to contain_exactly("a", "c")
    end

    it "stringifies symbol keys" do
      expect(described_class.to_item(:pk => "x")).to eq("pk" => { s: "x" })
    end
  end

  describe ".padded_epoch via Keys" do
    it "pads to a fixed width so lexicographic order matches numeric order" do
      early = Bassinet::Dynamo::Keys.padded_epoch(1_000)
      late  = Bassinet::Dynamo::Keys.padded_epoch(2_000)
      same_width = Bassinet::Dynamo::Keys.padded_epoch(999_999_999_999)

      expect(early.length).to eq(late.length)
      expect(late.length).to eq(same_width.length)
      expect(early < late).to be(true)
    end
  end
end

RSpec.describe Bassinet::Dynamo::Keys do
  describe ".event_sk" do
    it "orders by time, then event id" do
      a = described_class.event_sk(1_500, "aaa")
      b = described_class.event_sk(1_500, "bbb")
      c = described_class.event_sk(1_600, "aaa")

      expect([a, b, c].sort).to eq([a, b, c])
    end

    it "round-trips through parse_event_sk" do
      sk = described_class.event_sk(1_762_699_000_123, "018f-abc")
      expect(described_class.parse_event_sk(sk)).to eq([1_762_699_000_123, "018f-abc"])
    end

    it "returns nil for a non-event sort key" do
      expect(described_class.parse_event_sk("META")).to be_nil
    end
  end

  describe "range bounds" do
    it "brackets every event at the same instant" do
      at = 1_762_699_000_000
      lower = described_class.event_sk_lower(at)
      upper = described_class.event_sk_upper(at)

      %w[aaa mmm zzz].each do |id|
        sk = described_class.event_sk(at, id)
        expect(sk >= lower).to be(true), "#{sk} below lower"
        expect(sk <= upper).to be(true), "#{sk} above upper"
      end
    end
  end
end
