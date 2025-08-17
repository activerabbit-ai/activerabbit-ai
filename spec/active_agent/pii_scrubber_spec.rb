# frozen_string_literal: true

RSpec.describe ActiveAgent::Client::PiiScrubber do
  let(:configuration) { ActiveAgent::Client::Configuration.new }
  let(:scrubber) { described_class.new(configuration) }

  describe "#scrub" do
    context "with hash data" do
      it "scrubs PII fields" do
        data = {
          name: "John Doe",
          email: "john@example.com",
          password: "secret123",
          age: 30
        }

        result = scrubber.scrub(data)

        expect(result[:name]).to eq("[FILTERED]")
        expect(result[:email]).to eq("[FILTERED]")
        expect(result[:password]).to eq("[FILTERED]")
        expect(result[:age]).to eq(30)
      end

      it "scrubs nested hashes" do
        data = {
          user: {
            name: "John Doe",
            email: "john@example.com",
            preferences: {
              newsletter: true
            }
          },
          password: "secret123"
        }

        result = scrubber.scrub(data)

        expect(result[:user][:name]).to eq("[FILTERED]")
        expect(result[:user][:email]).to eq("[FILTERED]")
        expect(result[:user][:preferences][:newsletter]).to be true
        expect(result[:password]).to eq("[FILTERED]")
      end

      it "handles symbol and string keys" do
        data = {
          "password" => "secret123",
          :email => "john@example.com",
          "safe_field" => "safe_value"
        }

        result = scrubber.scrub(data)

        expect(result["password"]).to eq("[FILTERED]")
        expect(result[:email]).to eq("[FILTERED]")
        expect(result["safe_field"]).to eq("safe_value")
      end
    end

    context "with array data" do
      it "scrubs arrays of hashes" do
        data = [
          { name: "John", email: "john@example.com" },
          { name: "Jane", email: "jane@example.com" }
        ]

        result = scrubber.scrub(data)

        expect(result[0][:name]).to eq("[FILTERED]")
        expect(result[0][:email]).to eq("[FILTERED]")
        expect(result[1][:name]).to eq("[FILTERED]")
        expect(result[1][:email]).to eq("[FILTERED]")
      end

      it "scrubs mixed arrays" do
        data = [
          "john@example.com",
          { password: "secret" },
          42,
          "safe string"
        ]

        result = scrubber.scrub(data)

        expect(result[0]).to eq("[FILTERED]") # Email scrubbed
        expect(result[1][:password]).to eq("[FILTERED]")
        expect(result[2]).to eq(42)
        expect(result[3]).to eq("safe string")
      end
    end

    context "with string data" do
      it "scrubs email addresses" do
        text = "Contact us at support@example.com or admin@test.org"
        result = scrubber.scrub(text)
        expect(result).to eq("Contact us at [FILTERED] or [FILTERED]")
      end

      it "scrubs phone numbers" do
        text = "Call us at 123-456-7890 or (555) 123-4567"
        result = scrubber.scrub(text)
        expect(result).to eq("Call us at [FILTERED] or [FILTERED]")
      end

      it "scrubs credit card numbers" do
        text = "Card number: 4532-1234-5678-9012"
        result = scrubber.scrub(text)
        expect(result).to eq("Card number: [FILTERED]")
      end

      it "scrubs social security numbers" do
        text = "SSN: 123-45-6789"
        result = scrubber.scrub(text)
        expect(result).to eq("SSN: [FILTERED]")
      end

      it "scrubs IP addresses partially" do
        text = "Server IP: 192.168.1.100"
        result = scrubber.scrub(text)
        expect(result).to eq("Server IP: 192.xxx.xxx.xxx")
      end

      it "doesn't scrub invalid credit card numbers" do
        text = "Order ID: 1234567890123456" # 16 digits but fails Luhn check
        result = scrubber.scrub(text)
        expect(result).to eq("Order ID: 1234567890123456")
      end

      it "doesn't scrub repeated digits as SSN" do
        text = "ID: 111111111"
        result = scrubber.scrub(text)
        expect(result).to eq("ID: 111111111")
      end
    end

    context "with non-PII data" do
      it "returns data unchanged" do
        data = {
          id: 123,
          status: "active",
          created_at: "2023-01-01",
          metadata: {
            version: "1.0",
            debug: true
          }
        }

        result = scrubber.scrub(data)
        expect(result).to eq(data)
      end
    end

    context "with custom PII fields" do
      before do
        configuration.pii_fields = %w[custom_secret internal_id]
      end

      it "scrubs custom fields" do
        data = {
          custom_secret: "secret_value",
          internal_id: "internal_123",
          public_field: "public_value"
        }

        result = scrubber.scrub(data)

        expect(result[:custom_secret]).to eq("[FILTERED]")
        expect(result[:internal_id]).to eq("[FILTERED]")
        expect(result[:public_field]).to eq("public_value")
      end
    end
  end
end
