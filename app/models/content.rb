require 'set'

class Content < ActiveRecord::Base
  belongs_to :text_filter

  has_many :notifications, :foreign_key => 'content_id'
  has_many :notify_users, :through => :notifications,
    :source => 'notify_user',
    :uniq => true

  def notify_users=(collection)
    return notify_users.clear if collection.empty?
    self.class.transaction do
      self.notifications.clear
      collection.uniq.each do |u|
        self.notifications.build(:notify_user => u)
      end
      notify_users.target = collection
    end
  end

  has_many :triggers, :as => :pending_item, :dependent => :delete_all

  serialize :whiteboard

  attr_accessor :just_changed_published_status
  alias_method :just_changed_published_status?, :just_changed_published_status

  include Stateful

  @@content_fields = Hash.new
  @@html_map       = Hash.new

  def invalidates_cache?(on_destruction = false)
    if on_destruction
      just_changed_published_status? || published?
    else
      changed? && published? || just_changed_published_status?
    end
  end

  class << self
    # Quite a bit of this isn't needed anymore.
    def content_fields(*attribs)
      @@content_fields[self] = ((@@content_fields[self]||[]) + attribs).uniq
      @@html_map[self] = nil
      attribs.each do | field |
        define_method("#{field}=") do | newval |
          if self[field] != newval
            changed
            self[field] = newval
          end
          self[field]
        end
        unless self.method_defined?("#{field}_html")
          define_method("#{field}_html") do
            typo_deprecated "Use html(:#{field})"
            html(field.to_sym)
          end
        end
      end
    end

    def html_map(field=nil)
      unless @@html_map[self]
        @@html_map[self] = Hash.new
        instance = self.new
        @@content_fields[self].each do |attrib|
          @@html_map[self][attrib] = true
        end
      end
      if field
        @@html_map[self][field]
      else
        @@html_map[self]
      end
    end

    def find_published(what = :all, options = {})
      with_scope(:find => {:order => default_order, :conditions => {:published => true}}) do
        find what, options
      end
    end

    def default_order
      'published_at DESC'
    end

    def find_already_published(what = :all, at = nil, options = { })
      if what.respond_to?(:has_key?)
        what, options = :all, what
      elsif at.respond_to?(:has_key?)
        options, at = at, nil
      end
      at ||= options.delete(:at) || Time.now
      with_scope(:find => { :conditions => ['published_at < ?', at]}) do
        find_published(what, options)
      end
    end
    
    def find_by_published_at(column_name = :published_at)
      from_where = "FROM #{self.table_name} WHERE #{column_name} is not NULL AND type='#{self.name}'"

      # Implement adapter-specific groupings below, or allow us to fall through to the generic ruby-side grouping
      
      if defined?(ActiveRecord::ConnectionAdapters::MysqlAdapter) && self.connection.is_a?(ActiveRecord::ConnectionAdapters::MysqlAdapter)
        # MySQL uses date_format
        find_by_sql("SELECT date_format(#{column_name}, '%Y-%m') AS publication #{from_where} GROUP BY publication ORDER BY publication DESC")
        
      elsif defined?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter) && self.connection.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter)
        # PostgreSQL uses to_char
        find_by_sql("SELECT to_char(#{column_name}, 'YYYY-MM') AS publication #{from_where} GROUP BY publication ORDER BY publication DESC")
        
      else
        # If we don't have an adapter-safe conversion from date -> YYYY-MM,
        # we'll do the GROUP BY server-side. There won't be very many objects
        # in this array anyway.
        date_map = {}
        dates = find_by_sql("SELECT #{column_name} AS publication #{from_where}")
    
        dates.map! do |d|
          d.publication = Time.parse(d.publication).strftime('%Y-%m')
          d.freeze
          if !date_map.has_key?(d.publication)
            date_map[d.publication] = true
            d
          end
        end
        dates.reject!{|d| d.blank? || d.publication.blank?}
        dates.sort!{|a,b| b.publication <=> a.publication}
        
        dates
      end
    end
  end

  def content_fields
    @@content_fields[self.class]
  end

  def html_map(field=nil)
    self.class.html_map(field)
  end

  def cache_key(field)
    id ? "contents_html/#{id}/#{field}" : nil
  end

  # Return HTML for some part of this object.  It will be fetched from the
  # cache if possible, or regenerated if needed.
  def html(field = :all)
    if field == :all
      generate_html(:all, content_fields.map{|f| self[f].to_s}.join("\n\n"))
    elsif self.class.html_map(field)
      generate_html(field)
    else
      raise "Unknown field: #{field.inspect} in article.html"
    end
  end

  # Generate HTML for a specific field using the text_filter in use for this
  # object.  The HTML is cached in the fragment cache, using the +ContentCache+
  # object in @@cache.
  def generate_html(field, text = nil)
    text ||= self[field].to_s
    html = text_filter.filter_text_for_content(blog, text, self) || text
    html_postprocess(field,html).to_s
  end

  # Post-process the HTML.  This is a noop by default, but Comment overrides it
  # to enforce HTML sanity.
  def html_postprocess(field,html)
    html
  end

  def whiteboard
    self[:whiteboard] ||= Hash.new
  end

  # The default text filter.  Generally, this is the filter specified by blog.text_filter,
  # but comments may use a different default.
  def default_text_filter
    blog.text_filter.to_text_filter
  end

  # Grab the text filter for this object.  It's either the filter specified by
  # self.text_filter_id, or the default specified in the default blog object.
  def text_filter
    if self[:text_filter_id] && !self[:text_filter_id].zero?
      TextFilter.find(self[:text_filter_id])
    else
      default_text_filter
    end
  end

  # Set the text filter for this object.
  def text_filter=(filter)
    returning(filter.to_text_filter) do |tf|
      if tf.id != text_filter_id
        changed if !new_record? && published?
      end
      self.text_filter_id = tf.id
    end
  end

  # Changing the title flags the object as changed
  def title=(new_title)
    if new_title == self[:title]
      self[:title]
    else
      changed if !new_record? && published?
      self[:title] = new_title
    end
  end

  def blog
    Blog.default
  end

  def publish!
    self.published = true
    self.save!
  end

  def withdraw!
    self.withdraw
    self.save!
  end

  def published_at
    self[:published_at] || self[:created_at]
  end

  def send_notification_to_user(user)
    notify_user_via_email(user)
  end

  def really_send_notifications
    returning true do
      interested_users.each do |value|
        send_notification_to_user(value)
      end
    end
  end

  def to_atom xml
    xml.entry self, :url => permalink_url do |entry|
      atom_author(entry)
      atom_title(entry)
      atom_groupings(entry)
      atom_enclosures(entry)
      atom_content(entry)
    end
  end

  def to_rss(xml)
    xml.item do
      rss_title(xml)
      rss_description(xml)
      xml.pubDate published_at.rfc822
      xml.guid "urn:uuid:#{guid}", :isPermaLink => "false"
      rss_author(xml)
      rss_comments(xml)
      rss_groupings(xml)
      rss_enclosure(xml)
      rss_trackback(xml)
      xml.link permalink_url
    end
  end

  def rss_comments(xml)
  end

  def rss_description(xml)
    if self.user && self.user.name
      rss_desc = "<hr /><p><small>#{_('Original article writen by')} #{self.user.name} #{_('and published on')} <a href='#{blog.base_url}'>#{blog.blog_name}</a> | <a href='#{self.permalink_url}'>#{_('direct link to this article')}</a> | #{_('If you are reading this article elsewhere than')} <a href='#{blog.base_url}'>#{blog.blog_name}</a>, #{_('it has been illegally reproduced and without proper authorization')}.</small></p>"
    else
      rss_desc = ""
    end
    post = html(blog.show_extended_on_rss ? :all : :body)
    xml.description(blog.rss_description ? post + rss_desc : post)
  end

  def rss_groupings(xml)
  end

  def rss_enclosure(xml)
  end

  def rss_trackback(xml)
  end

  def atom_groupings(xml)
  end

  def atom_enclosures(xml)
  end

  def atom_content(xml)
    xml.content(:type => 'xhtml') do
      xml.div(:xmlns => 'http://www.w3.org/1999/xhtml') { xml << html(:all) }
    end
  end


  # deprecated
  def full_html
    typo_deprecated "use .html instead"
    html
  end
end

class Object
  def to_text_filter
    TextFilter.find_by_name(self.to_s) || TextFilter.find_by_name('none')
  end
end

class ContentTextHelpers
  include ActionView::Helpers::TagHelper
  include ActionView::Helpers::SanitizeHelper
  include ActionView::Helpers::TextHelper
  extend ActionView::Helpers::SanitizeHelper::ClassMethods
end

