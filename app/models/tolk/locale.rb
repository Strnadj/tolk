require 'tolk/config'
require 'tolk/pagination'

module Tolk
  class Locale < ActiveRecord::Base
    include Tolk::Pagination::Methods

    self.table_name = "#{Tolk::Config.table_prefix}tolk_locales"

    def self._dump_path
      # Necessary to acces rails.root at runtime !
      @dump_path ||= Tolk.config.dump_path.is_a?(Proc) ? instance_eval(&Tolk.config.dump_path) : Tolk.config.dump_path
    end

    has_many :translations, :class_name => 'Tolk::Translation', :dependent => :destroy
    has_many :phrases, :through => :translations, :class_name => 'Tolk::Phrase'

    accepts_nested_attributes_for :translations, :reject_if => proc { |attributes| attributes['text'].blank? }
    before_validation :remove_invalid_translations_from_target, :on => :update

    cattr_accessor :locales_config_path
    self.locales_config_path = self._dump_path

    cattr_accessor :primary_locale_name
    self.primary_locale_name = Tolk.config.primary_locale_name || I18n.default_locale.to_s

    include Tolk::Sync
    include Tolk::Import

    validates_uniqueness_of :name
    validates_presence_of :name

    cattr_accessor :special_prefixes
    self.special_prefixes = ['activerecord.attributes']

    cattr_accessor :special_keys
    self.special_keys = ['activerecord.models']

    PLURALIZATION_KEYS = ['none', 'zero', 'one', 'two', 'few', 'many', 'other']

    class << self
      def primary_locale(reload = false)
        @_primary_locale = nil if reload
        @_primary_locale ||= begin
          raise "Primary locale is not set. Please set Locale.primary_locale_name in your application's config file" unless self.primary_locale_name
          where(name: self.primary_locale_name).first_or_create
        end
      end

      def primary_language_name
        primary_locale.language_name
      end

      def secondary_locales
        all - [primary_locale]
      end

      def dump_all(*args)
        secondary_locales.each { |locale| locale.dump(*args) }
      end

      def dump_yaml(name, *args)
        where(name: name).first.dump(*args)
      end

      def special_key_or_prefix?(prefix, key)
        self.special_prefixes.include?(prefix) || self.special_keys.include?(key)
      end

      # http://cldr.unicode.org/index/cldr-spec/plural-rules - TODO: usage of 'none' isn't standard-conform

      def pluralization_data?(data)
        keys = data.keys.map(&:to_s)
        keys.all? {|k| PLURALIZATION_KEYS.include?(k) }
      end
    end

    def dump(to = self.locales_config_path, exporter = Tolk::Export)
      exporter.dump(name: name, data: to_hash, destination: to)
    end

    def has_updated_translations?
      translations.where(Tolk::Translation.table_name => { primary_updated: true }).any?
    end

    def phrases_with_translation(page = nil)
      find_phrases_with_translations(page, :"#{Tolk::Translation.table_name}.primary_updated" => false)
    end

    def phrases_with_updated_translation(page = nil)
      find_phrases_with_translations(page, :"#{Tolk::Translation.table_name}.primary_updated" => true)
    end

    def count_phrases_without_translation
      existing_ids = self.translations.pluck(&:phrase_id).uniq
      Tolk::Phrase.count - existing_ids.count
    end

    def count_phrases_with_updated_translation(page = nil)
      phrases_with_updated_translation(page).count
    end

    def phrases_without_translation(page = nil)
      phrases = Tolk::Phrase.order(key: :asc)

      existing_ids = self.translations.pluck(:phrase_id).uniq

      if existing_ids.any?
        phrases = phrases.where.not(Tolk::Phrase.table_name => { id: existing_ids })
      end

      phrases.preload(:translations).public_send(pagination_method, page)
    end

    def search_phrases(query, scope, key_query, page = nil)
      return [] unless query.present? || key_query.present?

      translations = case scope
      when :origin
        Tolk::Locale.primary_locale.translations.containing_text(query)
      else # :target
        self.translations.containing_text(query)
      end

      phrases = Tolk::Phrase.order(key: :asc)
      phrases = phrases.containing_text(key_query)

      phrases = phrases.where(Tolk::Phrase.table_name => { id: translations.map(&:phrase_id).uniq })
      phrases.public_send(pagination_method, page)
    end

    def search_phrases_without_translation(query, page = nil)
      return phrases_without_translation(page) unless query.present?

      phrases = Tolk::Phrase.order(key: :asc)

      found_translations_ids = Tolk::Locale.primary_locale.translations.where(["#{Tolk::Translation.table_name}.text LIKE ?", "%#{query}%"]).to_a.map(&:phrase_id).uniq
      existing_ids = self.translations.pluck(:phrase_id).uniq

      if existing_ids.any?
        phrases = phrases.where.not(id: existing_ids + found_translations_ids)
      end

      result = phrases.public_send(pagination_method, page)
      ActiveRecord::Associations::Preloader.new result, :translations

      result
    end

    def to_hash
      data = translations.joins(:phrase).order("#{Tolk::Phrase.table_name}.key ASC").pluck("#{Tolk::Phrase.table_name}.key, text").
      each_with_object(Hash.new(0)) do |translation, locale|
        if translation[0].include?(".")
          locale.deep_merge!(unsquish(translation[0], translation[1]))
        else
          locale[translation[0]] = translation[1]
        end
      end
      { name => data }
    end

    def to_param
      name.parameterize
    end

    def primary?
      name == self.class.primary_locale_name
    end

    def language_name
      Tolk.config.mapping[self.name] || self.name
    end

    def get(key)
      if phrase = Tolk::Phrase.where(key: key).first
        t = self.translations.where(:phrase_id => phrase.id).first
        t.text if t
      end
    end

    def translations_with_html
      translations
        .where("text LIKE '%>%' AND text LIKE '%<%' AND key NOT LIKE '%_html'")
        .preload(:phrase)
    end

    def self.rename(old_name, new_name)
      if old_name.blank? || new_name.blank?
        "You need to provide both names, aborting."
      else
        if locale = where(name: old_name).first
          locale.name = new_name
          locale.save
          "Locale ' #{old_name}' was renamed '#{new_name}'"
        else
          "Locale with name '#{old_name}' not found."
        end
      end
    end

    private


    def remove_invalid_translations_from_target
      self.translations.target.dup.each do |t|
        unless t.valid?
          self.translations.target.delete(t)
        else
          t.updated_at_will_change!
        end
      end

      true
    end

    def find_phrases_with_translations(page, conditions = {})
      result = Tolk::Phrase.joins(:translations).where({ :"#{Tolk::Translation.table_name}.locale_id" => self.id }.merge(conditions)).order(key: :asc).public_send(pagination_method, page)

      result.each do |phrase|
        phrase.translation = phrase.translations.for(self)
      end

      if Rails.version =~ /^4\.0/
        ActiveRecord::Associations::Preloader.new result, :translations
      else
        ActiveRecord::Associations::Preloader.new().preload(result, :translations)
      end

      result
    end

    def unsquish(string, value)
      if string.is_a?(String)
        unsquish(string.split("."), value)
      elsif string.size == 1
        { string.first => value }
      else
        key  = string[0]
        rest = string[1..-1]
        { key => unsquish(rest, value) }
      end
    end
  end
end
