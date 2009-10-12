#!/usr/bin/ruby1.9
# -*- coding: utf-8 -*-

=begin
= PDF Inspector
* help to inspect PDF files

== Requirements
* Ruby 1.9
* Ruby/GTK2

== Usage
* ruby1.9 pdf-inspector.rb some.pdf

== License
The MIT License

Copyright (c) 2009 Kazuhiro NISHIYAMA

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
=end

require 'gtk2'
require 'pp'
require 'set'
require 'strscan'
require 'zlib'

class PDF_Parser
  def initialize(filename)
    pdf = open(filename, "rb"){|f| f.read }
    if /\A%PDF/ !~ pdf
      raise("#{filename} is not PDF")
    end
    @filename = filename
    @pdf = pdf
    @objs = {}
    @debug = false
  end

  Stream = Struct.new(:c) do
    def inspect
      "<#{self.class} bytesize=#{c.bytesize}>"
    end
    def pretty_print(q)
      q.text("<#{self.class} bytesize=#{c.bytesize}>")
    end
  end
  Obj = Struct.new(:obj_id, :generation, :c)
  ObjRef = Struct.new(:obj_id, :generation)

  WHITE_SPACES = '\x00\x09\x0a\x0c\x0d\x20'
  DELIMITERS = Regexp.quote('()<>[]{}/%')

  def parse!
    @s = StringScanner.new(@pdf)
    @s.scan(/^%PDF-(1\.\d)(?:\r?\n|\r)/) or raise "invalid PDF"
    @version = @s[1]
    stack = []
    until @s.eos?
      case
      when @s.scan(/%[^\r\n]+/)
        dp :comment, @s.matched

      when @s.scan(/true/)
        dp :true
        stack.push true
      when @s.scan(/false/)
        dp :false
        stack.push false

      when @s.scan(/[+\-]?\d*\.\d+/), @s.scan(/[+\-]?\d+\.?/)
        num = @s.matched
        dp :numeric, num
        stack.push num

      when @s.scan(/\((?<s>[^()]*|\(\g<s>\)|\\[nrtbf()\\\n]|\\\d{2,3})*\)/)
        str = @s.matched
        dp :literal_string, str
        stack.push str
      when @s.scan(/<[0-9A-Fa-f]*>/)
        str = @s.matched
        dp :hexadecimal_string, str
        stack.push str

      when @s.scan(/\/[^#{WHITE_SPACES}#{DELIMITERS}]+/o)
        str = @s.matched
        dp :name_object, str
        stack.push str
        # @debug = true if str == "/Creator"

      when @s.scan(/\[/)
        dp :begin_array
        stack.push :begin_array
      when @s.scan(/\]/)
        dp :end_array
        array = []
        until (e = stack.pop) == :begin_array
          array.unshift e
        end
        stack.push array
        dp :end_array, array

      when @s.scan(/<</)
        dp :begin_dict
        stack.push :begin_dict
      when @s.scan(/>>/)
        dp :end_dict
        array = []
        until (e = stack.pop) == :begin_dict
          array.unshift e
        end
        dict = Hash[*array]
        stack.push dict
        dp :end_dict, dict

      when @s.scan(/stream.+?endstream/m)
        str = Stream.new(@s.matched)
        dp :stream, str
        stack.push str

      when @s.scan(/null/)
        dp :null
        stack.push nil

      when @s.scan(/obj/)
        generation = stack.pop
        obj_id = stack.pop
        obj = Obj.new(obj_id, generation)
        @objs["#{obj_id} #{generation}"] = obj
        stack.push obj
        dp :obj, obj
      when @s.scan(/endobj/)
        dp :end_obj
        array = []
        until (e = stack.pop).is_a?(Obj)
          array.unshift e
        end
        e.c = array
        stack.push e
        dp :end_obj, e

      when @s.scan(/R/)
        generation = stack.pop
        obj_id = stack.pop
        ref = ObjRef.new(obj_id, generation)
        stack.push ref
        dp :obj_ref, ref

      when @s.scan(/xref/)
        @xref = @s.matched
        dp :xref
        @s.scan(/(?:\r?\n|\r)(\d+) (\d+)\s+/)
        xref_nums = @s.matched
        @xref += @s.matched
        Integer(@s[2]).times do
          @s.scan(/[^\r\n]+(?:\r?\n|\r)/)
          @xref += @s.matched
        end
        dp :xref, xref_nums

      when @s.scan(/trailer/)
        dp :trailer
        stack.push :trailer

      when @s.scan(/startxref/)
        dp :startxref
        if @trailer
          @trailer.update(stack.pop)
        else
          @trailer = stack.pop
        end
        e = stack.pop
        if e != :trailer
          raise "startxref: unexpected stack top: #{e.inspect}"
        end
        dp :startxref, "trailer=", @trailer

      when @s.scan(/.+/)
        raise [:ignore, @s.matched].inspect
      end
      @s.scan(/[#{WHITE_SPACES}]*/o) # skip white spaces
    end
    @body = stack
  ensure
    pp stack if @debug
  end

  def dp(*args)
    p args if @debug
  end

  attr_reader :trailer

  def root
    @trailer["/Root"]
  end

  def ref(obj_ref)
    @objs["#{obj_ref.obj_id} #{obj_ref.generation}"]
  end

  def catalog
    ref(root)
  end

  def pages
    ref(catalog.c[0]["/Pages"])
  end
end

class Array
  def each_pair
    each_with_index do |e, i|
      yield i, e
    end
  end
end

class PDF_Inspector
  def initialize
    @window = ::Gtk::Window.new
    @window.signal_connect("destroy") { Gtk.main_quit }

    init_tree_view
    init_inspect_text_view
    paned = Gtk::HPaned.new

    scrolled_win = Gtk::ScrolledWindow.new
    scrolled_win.add(@tv)
    scrolled_win.set_policy(Gtk::POLICY_AUTOMATIC, Gtk::POLICY_ALWAYS)
    paned.pack1(scrolled_win, true, false)

    scrolled_win = Gtk::ScrolledWindow.new
    scrolled_win.add(@inspect_text_view)
    scrolled_win.set_policy(Gtk::POLICY_AUTOMATIC, Gtk::POLICY_ALWAYS)
    paned.pack2(scrolled_win, false, true)

    paned.set_position 400
    @window.add(paned)
    @window.set_size_request(800, 600)
    @window.show_all
  end

  %w"COL_KEY COL_SHORT_KEY COL_VAL COL_OBJ".each_with_index do |e, i|
    const_set(e, i)
  end

  def init_tree_view
    @store = ::Gtk::TreeStore.new(String, String, String, Object)
    @tv = Gtk::TreeView.new(@store)
    @tv.set_rules_hint(true)

    @tv.signal_connect("row-activated") do |view, path, column|
      row_activated(view, path, column)
    end

    @tv.signal_connect("row-expanded") do |view, iter, path|
      row_expanded(view, iter, path)
    end

    renderer = Gtk::CellRendererText.new
    col = Gtk::TreeViewColumn.new("Key", renderer, "text" => COL_SHORT_KEY)
    @tv.append_column(col)

    renderer = Gtk::CellRendererText.new
    col = Gtk::TreeViewColumn.new("Value", renderer, "text" => COL_VAL)
    @tv.append_column(col)
  end

  def load_pdf(filename)
    @window.title = "#{$0} - #{filename}"
    @pdf = PDF_Parser.new(filename)
    @pdf.parse!
    @seen = Set.new
    add_node(nil, "trailer", @pdf.trailer)
    # @tv.expand_all
  end

  def col_short_key(parent, key)
    if parent
      key[(parent[COL_KEY].size)..-1]
    else
      key
    end
  end
  private :col_short_key

  PLACEHOLDER = "(placeholder)"

  def row_expanded(view, parent, path)
    parent.n_children.times do |n|
      child = parent.nth_child(n)
      if child && child[COL_SHORT_KEY] == PLACEHOLDER
        key = child[COL_KEY]
        obj = child[COL_OBJ]
        child[COL_VAL] = "(#{obj.class})"
        child[COL_SHORT_KEY] = col_short_key(parent, key)
        obj.each_pair do |k, v|
          add_node(child, "#{key}[#{k}]", v)
        end
      end
    end
  end

  def add_node(parent, key, obj, level=0)
    case obj
    when PDF_Parser::ObjRef
      iter = @store.append(parent)
      iter[COL_KEY] = key
      iter[COL_SHORT_KEY] = col_short_key(parent, key)
      iter[COL_OBJ] = obj
      obj = @pdf.ref(obj)
      is_seen = @seen.include?(obj)
      @seen.add(obj)
      if is_seen
        iter[COL_VAL] = "id=#{obj.obj_id} generation=#{obj.generation} ..."
      elsif obj.c.size == 1
        iter[COL_VAL] = "id=#{obj.obj_id} generation=#{obj.generation}"
        add_node(iter, key, obj.c[0], level+1)
      elsif obj.c.size == 0
        iter[COL_VAL] = "id=#{obj.obj_id} generation=#{obj.generation} (empty)"
      else
        iter[COL_VAL] = "id=#{obj.obj_id} generation=#{obj.generation}"
        add_node(iter, key, obj.c, level+1)
      end
    when Array, Hash
      if obj.size >= 3 && !col_short_key(parent, key).empty?
        if level < 1
          iter = @store.append(parent)
          iter[COL_KEY] = key
          iter[COL_VAL] = "(#{obj.class})"
          iter[COL_SHORT_KEY] = col_short_key(parent, key)
          iter[COL_OBJ] = obj
          obj.each_pair do |k, v|
            add_node(iter, "#{key}[#{k}]", v, level+1)
          end
        else
          placeholder = @store.append(parent)
          placeholder[COL_KEY] = key
          placeholder[COL_SHORT_KEY] = PLACEHOLDER
          placeholder[COL_OBJ] = obj
        end
      else
        obj.each_pair do |k, v|
          add_node(parent, "#{key}[#{k}]", v, level+1)
        end
      end
    else
      iter = @store.append(parent)
      iter[COL_KEY] = key.to_s
      iter[COL_VAL] = obj.inspect
      iter[COL_SHORT_KEY] = col_short_key(parent, key)
      iter[COL_OBJ] = obj
    end
  end

  def row_activated(view, path, column)
    iter = @store.get_iter(path)
    obj = iter[COL_OBJ]
    case obj
    when PDF_Parser::ObjRef
      data = @pdf.ref(obj).pretty_inspect
    when PDF_Parser::Stream
      stream = obj.c[/\Astream\r?\n(.+)endstream\z/m, 1]
      begin
        case @pdf.ref(iter.parent[COL_OBJ]).c[0]["/Filter"]
        when "/FlateDecode"
          stream = Zlib::Inflate.inflate(stream)
        end
      rescue => e
        puts e.backtrace
        p e
      end
      if stream.ascii_only?
        data = stream
      elsif /\0/ =~ stream
        data = ""
        stream.each_byte.with_index do |b, i|
          if i % 32 == 0
            data << sprintf("\n%08x ", i)
          else
            data << " "
          end
          data << sprintf("%02x", b)
        end
        data.sub!(/\A\n/, '')
      else
        data = ""
        stream.each_line do |line|
          data << line.dump << "\n"
        end
      end
    else
      data = obj.pretty_inspect
    end
    @inspect_text_view.buffer.text = data
  end

  def init_inspect_text_view
    @inspect_text_view = Gtk::TextView.new
    @inspect_text_view.set_editable false
  end
end

if __FILE__ == $0
  filename = ARGV.shift
  unless filename
    abort("usage: #{$0} some.pdf")
  end
  inspector = PDF_Inspector.new
  inspector.load_pdf(filename)
  Gtk.main
end
