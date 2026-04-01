# frozen_string_literal: true

require 'nokogiri'
require 'uri'

# Rewrites an HTML document so that every URL (links, scripts, images, forms,
# inline CSS, meta-refresh, etc.) is routed through Thallium's /proxy endpoint.
module HtmlRewriter
  PROXY_BASE = '/proxy?url='

  # Attributes that carry a single URL
  SINGLE_URL_ATTRS = {
    'a'          => %w[href],
    'link'       => %w[href],
    'script'     => %w[src],
    'img'        => %w[src],
    'iframe'     => %w[src],
    'frame'      => %w[src],
    'embed'      => %w[src],
    'source'     => %w[src srcset],
    'video'      => %w[src poster],
    'audio'      => %w[src],
    'track'      => %w[src],
    'form'       => %w[action],
    'input'      => %w[src],
    'blockquote' => %w[cite],
    'q'          => %w[cite],
    'ins'        => %w[cite],
    'del'        => %w[cite]
  }.freeze

  def self.rewrite(html, base_url)
    doc = Nokogiri::HTML5(html) rescue Nokogiri::HTML(html)
    base_uri = safe_parse(base_url)

    inject_base_removal(doc)
    rewrite_single_url_attrs(doc, base_uri)
    rewrite_srcsets(doc, base_uri)
    rewrite_style_tags(doc, base_uri)
    rewrite_inline_styles(doc, base_uri)
    rewrite_meta_refresh(doc, base_uri)
    inject_thallium_script(doc)

    doc.to_html
  end

  # ── Rewrite single-URL attributes ─────────────────────────────────────────

  def self.rewrite_single_url_attrs(doc, base_uri)
    SINGLE_URL_ATTRS.each do |tag, attrs|
      doc.css(tag).each do |node|
        attrs.each do |attr|
          val = node[attr]
          next if val.nil? || val.strip.empty?
          next if val.start_with?('#', 'javascript:', 'mailto:', 'tel:', 'data:')

          absolute = resolve(val, base_uri)
          node[attr] = proxify(absolute) if absolute
        end
      end
    end
  end

  # ── srcset (comma-separated url descriptor pairs) ─────────────────────────

  def self.rewrite_srcsets(doc, base_uri)
    doc.css('[srcset]').each do |node|
      node['srcset'] = rewrite_srcset_value(node['srcset'], base_uri)
    end
  end

  def self.rewrite_srcset_value(srcset, base_uri)
    srcset.split(',').map do |part|
      url, descriptor = part.strip.split(/\s+/, 2)
      abs = resolve(url, base_uri)
      abs ? [proxify(abs), descriptor].compact.join(' ') : part
    end.join(', ')
  end

  # ── <style> tag contents ──────────────────────────────────────────────────

  def self.rewrite_style_tags(doc, base_uri)
    doc.css('style').each do |node|
      node.content = rewrite_css(node.content, base_uri)
    end
  end

  def self.rewrite_inline_styles(doc, base_uri)
    doc.css('[style]').each do |node|
      node['style'] = rewrite_css(node['style'], base_uri)
    end
  end

  def self.rewrite_css(css, base_uri)
    # url("...") and url('...') and url(...)
    css.gsub(/url\(\s*(['"]?)(.+?)\1\s*\)/i) do
      quote = $1
      url   = $2.strip
      next "url(#{quote}#{url}#{quote})" if url.start_with?('data:', '#')

      abs = resolve(url, base_uri)
      abs ? "url(#{quote}#{proxify(abs)}#{quote})" : "url(#{quote}#{url}#{quote})"
    end
  end

  # ── <meta http-equiv="refresh"> ───────────────────────────────────────────

  def self.rewrite_meta_refresh(doc, base_uri)
    doc.css('meta[http-equiv="refresh" i]').each do |node|
      content = node['content'].to_s
      if content =~ /url=(.+)/i
        url = $1.strip.gsub(/['"]/, '')
        abs = resolve(url, base_uri)
        node['content'] = content.sub(/url=.+/i, "url=#{proxify(abs)}") if abs
      end
    end
  end

  # ── Remove any <base> tags so our rewrites take effect ────────────────────

  def self.inject_base_removal(doc)
    doc.css('base').each(&:remove)
  end

  # ── Inject a small JS shim to intercept dynamic navigation ───────────────

  def self.inject_thallium_script(doc)
    script = doc.create_element('script')
    script['type'] = 'text/javascript'
    script.content = thallium_shim
    head = doc.at_css('head') || doc.at_css('body') || doc.root
    head.prepend_child(script) if head
  end

  def self.thallium_shim
    <<~JS
      (function(){
        var _open = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url) {
          if (url && !url.startsWith('/') && !url.startsWith('data:')) {
            try {
              var abs = new URL(url, location.href).href;
              url = '/proxy?url=' + encodeURIComponent(abs);
            } catch(e) {}
          }
          return _open.apply(this, arguments);
        };

        var _fetch = window.fetch;
        window.fetch = function(input, init) {
          if (typeof input === 'string' && !input.startsWith('/') && !input.startsWith('data:')) {
            try {
              var abs = new URL(input, location.href).href;
              input = '/proxy?url=' + encodeURIComponent(abs);
            } catch(e) {}
          }
          return _fetch.call(this, input, init);
        };
      })();
    JS
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  def self.resolve(url, base_uri)
    return nil if url.nil? || url.strip.empty?
    url = url.strip
    if url.start_with?('//')
      "#{base_uri.scheme}:#{url}"
    elsif url.start_with?('http://', 'https://')
      url
    else
      URI.join(base_uri.to_s, url).to_s rescue nil
    end
  end

  def self.proxify(url)
    "#{PROXY_BASE}#{URI.encode_www_form_component(url)}"
  end

  def self.safe_parse(url)
    URI.parse(url)
  rescue
    URI.parse('http://localhost')
  end
end
