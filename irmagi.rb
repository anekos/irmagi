#!/usr/bin/ruby
# vim: set fileencoding=utf-8 :

require 'serialport'
require 'json'
require 'pathname'
require 'sinatra/base'
require 'sinatra/reloader'


class IrMagician
  def initialize (path)
    @serial_port = SerialPort.new(path, 9600, 8, 1, 0)
    @serial_port.read_timeout = 5000
    skip_banner
  end

  def capture ()
    @serial_port.puts('c')
    response = @serial_port.gets
    if m = response.match(/\.{3} (\d+)/)
      m[1].to_i
    else
      response
    end
  end

  def dump ()
    @serial_port.puts('i,6')
    scale = @serial_port.gets.to_i(10)

    @serial_port.puts('i,1')
    size = @serial_port.gets.to_i(16)

    blocks = size / 64 + 1

    data =
      blocks.times.map do
        |block|
        @serial_port.puts('b,%d' % block)
        block_size = (block == blocks - 1) ? size % 64 : 64
        block_size.times.map do
          |offset|
          @serial_port.puts('d,%d' % offset)
          @serial_port.read(2).to_i(16).tap {
            @serial_port.read(1)
          }
        end
      end

    {'scale' => scale, 'data' => data}
  end

  def play ()
    @serial_port.puts('p')
    @serial_port.gets
  end

  def record (scale, blocks)
    size = blocks.map(&:size).inject(&:+)

    @serial_port.puts('n,%d' % size)
    @serial_port.puts('k,%d' % scale)
    @serial_port.gets

    blocks.each_with_index do
      |block, i|
      @serial_port.puts('b,%d' % i)
      block.each_with_index do
        |byte, j|
        @serial_port.puts('w,%d,%d' % [j, byte])
      end
    end
  end

  def reset (n = 0)
    @serial_port.puts('r,%d' % n)
    @serial_port.gets.chomp == 'OK'
  end

  private
  def skip_banner
    before = @serial_port.read_timeout
    @serial_port.read_timeout = -1 # no wait
    @serial_port.gets
    @serial_port.read_timeout = before
  end
end


class Profiles < Array
  IR_MAGI_DIR = Pathname(ENV['HOME']) + '.irmagi'

  def initialize
    super
    IR_MAGI_DIR.entries.select {|it| (IR_MAGI_DIR + it).file? } .sort.map {|it| it.sub_ext('') }.each { |it|
      self << it
    }
  end

  def read(name)
    JSON.parse(File.read(to_path(name)))
  end

  def write(name, json_object)
    content = JSON.pretty_generate(json_object)
    file = to_path(name)
    file.parent.mkpath
    File.write(file, content)
    file
  end

  def to_path (name)
    IR_MAGI_DIR + "#{name}.json"
  end
end


class Server < Sinatra::Base
  configure :development do
    register Sinatra::Reloader
  end

  enable :sessions

  get '/' do
    @message = session[:message]
    session[:message] = nil

    erb(wrap(<<-EOT))
  <% if @message %>
    <%= @message %>
  <% end %>
  <ol>
    <% settings.app.profiles.each do|it| %>
      <li><a href="./play/<%= it.to_s %>"><%= it.to_s %></a></li>
    <% end %>
  </ol>
EOT
  end

  get '/play/:profile' do
    profile = params[:profile]
    settings.app.play(profile)
    session[:message] = "OK: #{profile}"
    redirect to('/')
  end

  private
  def wrap (body)
    <<-"EOT"
<!DOCTYPE html>
<html>
  <head>
    <title>irmagi</title>
    <style type="text/css">
      .input {
        width: 100%;
        font-size: x-large;
      }
    </style>
    <meta name="viewport" content="width=device-width" />
  </head>
  <body>
    #{body}
  </body>
</html>
EOT
  end
end


class App
  attr_reader :profiles

  def initialize (path, command, name = nil)
    @irmagi = IrMagician.new(path)
    @profiles = Profiles.new

    case command
    when 'server'
      server(name)
    when 'dump'
      dump(name)
    when 'capture'
      capture(name)
    when 'play'
      play(name)
    when 'record'
      record(name)
    when 'list'
      list
    when 'reset'
      reset
    when 'nop'
      # DO NOTHING
    else
      STDERR.puts('Unknow command: %s' % command)
    end
  end

  def server (port)
    Server.set :app, self
    Server.set :port, port.to_i
    Server.run!
  end

  def list
    @profiles.each {|it| puts(it) }
  end

  def dump (name)
    dumped = @irmagi.dump
    json_text = JSON.pretty_generate(dumped)
    puts(json_text)
    if name
      file = @profiles.write(name, dumped)
      puts("Dumped: #{file}")
    end
  end

  def capture (name)
    reset
    puts(@irmagi.capture)
    dump(name) if name
  end

  def record (name)
    reset
    json = @profiles.read(name)
    @irmagi.record(json['scale'], json['data'])
  end

  def play (name)
    record(name) if name
    @irmagi.play()
  end

  def reset
    @irmagi.reset()
  end
end


App.new(*ARGV)
