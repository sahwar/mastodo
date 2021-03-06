# frozen_string_literal: true
# == Schema Information
#
# Table name: email_domain_blocks
#
#  id         :bigint(8)        not null, primary key
#  domain     :string           default(""), not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
require 'whois'

class EmailDomainBlock < ApplicationRecord
  include DomainNormalizable

  validates :domain, presence: true, uniqueness: true

  def self.block?(email)
    whitelist = ['gmail.com','protonmail.com']

    _, domain = email.split('@', 2)

    return true if domain.nil?

    begin
      domain = TagManager.instance.normalize_domain(domain)
    rescue Addressable::URI::InvalidURIError
      return true
    end
    return false if whitelist.include?(domain)

    whois = Whois::Client.new
    begin
      record = whois.lookup(domain)
    rescue Whois::Error => e
      Rails.logger.error("Whois lookup failed for '#{domain}': #{e.class}: #{e.message}")
      return true
    end
    return true if record.content.include? "movies.hecate"

    where(domain: domain).exists?
  end
end
