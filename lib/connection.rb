# Represents a connection with another peer
#
# The full protocol is documented in ../protocol/core.md

require 'socket'
require 'thread'
require 'openssl'
require 'conf'

class Connect
  attr_reader :peer, :access, :software, :friendly_name

  # Create a new Connect and begin communication with it.
  #
  # Outgoing connections will already know the share it is communicating with.
  def initialize socket, share=nil
    @share = share
    @socket = socket

    @incoming = !share

    @receiving_thread = Thread.new do
      handshake
      request_manifest
      receive_messages
    end
  end

  # Attempt to make an outbound connection with a peer
  def self.connect share, ip, port
    socket = TCPSocket.connect ip, port
    self.new socket, share
  end

  private

  def send type, opts=nil
    if !type.is_a? Message
      message = Message.new type, opts
    else
      message = type
    end

    if @send_queue
      @send_queue.push message
    else
      message.write_to_io @socket
    end
  end

  def start_send_thread
    @send_queue = Queue.new
    @sending_thread = Thread.new { send_messages }
  end

  def recv type=nil
    msg = Message.read_from_io @socket
    if type && msg.type.to_s != type.to_s
      warn "Unexpected message: #{msg[:type]}, expecting #{type}"
      return recv type
    end

    msg
  end

  def receive_messages
    loop do
      msg = recv
      begin
        handle msg
      rescue
        warn "Error handling message #{msg[:type].inspect}: #$!"
      end
    end
  end

  def handle msg
    case msg.type
    when :get_manifest
      if msg[:version] && msg[:version] == @share.version
        send :manifest_current
        return
      end
      send_manifest
    when :manifest_current
      receive_manifest @peer.manifest
      request_file
    when :manifest
      @peer.manifest = msg
      receive_manifest msg
      request_file
    when :update
    when :move
    when :get
      fp = @share.read_file msg[:path]
      res = Message.new :file_data, { path: msg[:path] }
      remaining = fp.size
      if msg[:range]
        fp.pos = msg[:range][0]
        res[:range] = msg[:range]
        remaining = msg[:range][1]
      end

      res.binary_data(remaining) do
        if remaining > 0
          data = fp.read [1024 * 256, remaining].max
          remaining -= data.size
          data
        else
          fp.close
          nil
        end
      end

      send res
    when :file_data
      @share.write_file msg[:path] do |f|
        msg.get_binary_data do |data|
          f.write data
        end
      end
    end
  end

  def send_manifest
    msg = Message.new :manifest
    msg[:peer] = @share.peer_id
    msg[:version] = @share.version
    msg[:files] = []
    @share.each do |file|
      next unless file.scanned?

      if file.deleted?
        obj = {
          path: file.path,
          utime: file.utime,
          deleted: true,
          id: file.id
        }
      else
        obj = {
          path: file.path,
          utime: file.utime,
          size: file.size,
          mtime: file.mtime,
          mode: file.mode,
          sha256: file.sha256,
          id: file.id,
          key: file.key,
        }
      end

      msg[:files] << obj
    end

    send msg
  end

  def receive_manifest msg
    @files = msg[:files]
    @remaining = @files.select { |file|
      next if file[:deleted]

      ours = @share.by_path file[:path]

      next if file[:utime] < ours[:utime]
      # FIXME We'd also want to skip it if there is a pending download of this
      # file from another peer with an even newer utime

      !ours || file[:sha256] != ours[:sha256]
    }
  end

  def request_file
    file = @remaining.sample
    send :get, {
      path: file[:path]
    }
  end

  def send_messages
    while msg = @send_queue.shift
      msg.write_to_io @socket
    end
  end

  def handshake
    if @incoming
      send :greeting, {
        software: Conf.version,
        protocol: [1],
        features: []
      }
    else
      greeting = recv :greeting

      unless greeting[:protocol].member? 1
        raise "Cannot communicate with peer, peer only knows versions #{greeting[:protocol].inspect}"
      end

      send :start, {
        software: Conf.version,
        protocol: 1,
        features: [],
        id: share.id,
        access: share.access_level,
        peer: share.peer_id,
      }
    end

    if @incoming
      start = recv :start
      @peer_id = start[:peer]
      @access = start[:access].to_sym
      @software = start[:software]
      @share = Share.by_id start[:id]
      if !@share
        send :cannot_start
        close
      end

      @level = greatest_common_access(@access, @share[:access])

      send :starttls, {
        peer: @share.peer_id,
        access: @level,
      }
    else
      starttls = recv :starttls
      @peer_id = starttls[:peer]
      @level = starttls[@level]
    end

    @tcp_socket = @socket

    @socket = OpenSSL::SSL::SSLSocket.new @tcp_socket, ssl_context

    start_send_thread

    send :identity, {
      name: Shares.friendly_name,
      time: Time.new.to_i,
    }

    identity = recv :identity
    @friendly_name = identity[:name]

    time_diff = identity[:time] - Time.new.to_i
    if time_diff.abs > 60
      raise "Peer clock is too far #{time_diff > 0 ? 'ahead' : 'behind'} yours (#{time_diff.abs} seconds)"
    end
  end

  def request_manifest
    if @peer.manifest && @peer.manifest.version
      send :get_manifest, {
        version: @peer.manifest.version
      }
    else
      send :get_manifest
    end
  end

  def greatest_common_access l1, l2
    levels = [:unknown, :untrusted, :read_only, :read_write]
    i1 = levels.index l1
    raise "Invalid access level: #{l1.inspect}" unless i1
    i2 = levels.index l2
    raise "Invalid access level: #{l2.inspect}" unless i2
    common = [i1, i2].min
    levels[common]
  end

  def ssl_context
    context = OpenSSL::SSL::SSLContext.new
    context.key = @share.key @level
    context.ciphers = ['TLS_DHE_PSK_WITH_AES_128_CBC_SHA']
    context.tmp_dh_callback = Proc.new do
      share.tls_dh_key
    end

    context
  end
end