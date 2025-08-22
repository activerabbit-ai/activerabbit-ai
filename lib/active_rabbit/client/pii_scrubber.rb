# frozen_string_literal: true

module ActiveRabbit
  module Client
    class PiiScrubber
      SCRUBBED_VALUE = "[FILTERED]"

      attr_reader :configuration

      def initialize(configuration)
        @configuration = configuration
      end

      def scrub(data)
        case data
        when Hash
          scrub_hash(data)
        when Array
          scrub_array(data)
        when String
          scrub_string(data)
        else
          data
        end
      end

      private

      def scrub_hash(hash)
        return hash unless hash.is_a?(Hash)

        hash.each_with_object({}) do |(key, value), scrubbed|
          if should_scrub_key?(key)
            scrubbed[key] = SCRUBBED_VALUE
          else
            scrubbed[key] = scrub(value)
          end
        end
      end

      def scrub_array(array)
        return array unless array.is_a?(Array)

        array.map { |item| scrub(item) }
      end

      def scrub_string(string)
        return string unless string.is_a?(String)

        scrubbed = string.dup

        # Scrub common PII patterns
        scrubbed = scrub_email_addresses(scrubbed)
        scrubbed = scrub_phone_numbers(scrubbed)
        scrubbed = scrub_credit_cards(scrubbed)
        scrubbed = scrub_social_security_numbers(scrubbed)
        scrubbed = scrub_ip_addresses(scrubbed)

        scrubbed
      end

      def should_scrub_key?(key)
        return false unless key

        key_str = key.to_s.downcase

        configuration.pii_fields.any? do |pii_field|
          case pii_field
          when String
            key_str.include?(pii_field.downcase)
          when Regexp
            key_str =~ pii_field
          else
            false
          end
        end
      end

      def scrub_email_addresses(string)
        # Match email addresses
        string.gsub(/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/, SCRUBBED_VALUE)
      end

      def scrub_phone_numbers(string)
        # Match various phone number formats
        patterns = [
          /\(\d{3}\)\s?\d{3}[-.]?\d{4}/, # (123) 456-7890, (123)456-7890
          /\b\d{3}[-.]?\d{3}[-.]?\d{4}\b/, # 123-456-7890, 123.456.7890, 1234567890
          /\b\+1[-.\s]?\d{3}[-.\s]?\d{3}[-.\s]?\d{4}\b/, # +1-123-456-7890
          /\b\d{3}\s\d{3}\s\d{4}\b/ # 123 456 7890
        ]

        patterns.reduce(string) do |str, pattern|
          str.gsub(pattern, SCRUBBED_VALUE)
        end
      end

      def scrub_credit_cards(string)
        # Match credit card patterns - be more permissive for testing
        patterns = [
          /\b\d{4}[-\s]\d{4}[-\s]\d{4}[-\s]\d{4}\b/, # 1234-5678-9012-3456
          /\b\d{13,19}\b/ # 13-19 consecutive digits
        ]

        patterns.reduce(string) do |str, pattern|
          str.gsub(pattern) do |match|
            digits = match.gsub(/\D/, '')
            # Only scrub if it looks like a credit card (passes basic Luhn check)
            if digits.length >= 13 && digits.length <= 19 && luhn_valid?(digits)
              SCRUBBED_VALUE
            else
              match
            end
          end
        end
      end

      def scrub_social_security_numbers(string)
        # Match SSN patterns
        patterns = [
          /\b\d{3}[-.\s]?\d{2}[-.\s]?\d{4}\b/, # 123-45-6789, 123.45.6789, 123 45 6789
          /\b\d{9}\b/ # 123456789 (9 consecutive digits)
        ]

        patterns.reduce(string) do |str, pattern|
          str.gsub(pattern) do |match|
            # Only scrub 9-digit sequences that look like SSNs
            digits = match.gsub(/\D/, '')
            if digits.length == 9 && !digits.match(/^0{9}$|^1{9}$|^2{9}$|^3{9}$|^4{9}$|^5{9}$|^6{9}$|^7{9}$|^8{9}$|^9{9}$/)
              SCRUBBED_VALUE
            else
              match
            end
          end
        end
      end

      def scrub_ip_addresses(string)
        # Match IPv4 addresses
        string.gsub(/\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b/) do |match|
          # Only scrub if it's a valid IP address
          octets = match.split('.')
          if octets.all? { |octet| octet.to_i <= 255 }
            # Keep first octet for debugging purposes
            "#{octets.first}.xxx.xxx.xxx"
          else
            match
          end
        end
      end

      def luhn_valid?(number)
        # Basic Luhn algorithm check for credit card validation
        digits = number.reverse.chars.map(&:to_i)

        sum = digits.each_with_index.sum do |digit, index|
          if index.odd?
            doubled = digit * 2
            doubled > 9 ? doubled - 9 : doubled
          else
            digit
          end
        end

        sum % 10 == 0
      end
    end
  end
end
