# In-memory hash structure, persisted to disk via log file.

require_relative 'log'

class Permahash
  # How inefficient the file should be before vacuuming
  MINIMUM_BLOAT_FACTOR = 4

  # Never vacuum if log has less than this many entries
  MINIMUM_VACUUM_SIZE = 4096

  HEADER = "CLEARSKIES PERMAHASH v1"

  # Create a new permahash, or load it from disk, depending on whether or not
  # `path` exists.
  def initialize path
    @path = path
    @hash = {}
    # FIXME Use locking to ensure that we don't open the logfile twice
    @logsize = 0
    exists = File.exists? path
    read_from_file if exists

    @logfile = File.open @path, 'ab'
    @logfile.sync = true

    @logfile.puts HEADER unless exists
  end

  # Get number of entries in the database
  def size
    @hash.size
  end

  # Loop through every key and value in the database
  def each &bl
    @hash.each(&bl)
  end

  # Retrieve a value by key
  def [] key
    @hash[key]
  end

  # Put value into database by key
  def []= key, val
    @hash[key] = val
    append 'r', key, val
  end

  # Save the given key again.  This should be done if the value inside is
  # changed, such as would be case if it were an array or object, since
  # the first time they were added they were just references.
  def save key
    append 'r', key, @hash[key]
  end

  # Delete key from database
  def delete key
    val = @hash.delete key
    append 'd', key, val
    val
  end

  # Get all values from the database
  def values
    @hash.values
  end

  # Get all keys present in the database
  def keys
    @hash.keys
  end

  # Close the database for writing.  Reads are still possible.
  def close
    @logfile.close
    @logfile = nil
  end

  # Delete the database file
  def delete_database!
    File.unlink @logfile
  end

  private
  # Save an update to disk
  def append oper, key, val=nil
    keyd = Marshal.dump key
    vald = Marshal.dump val

    entry = String.new
    entry << "#{oper}:#{keyd.size}:#{vald.size}\n"
    entry << keyd
    entry << vald
    @logfile.write entry

    @logsize += 1

    # Vacuum if log has gotten too large
    return unless @logsize > MINIMUM_VACUUM_SIZE
    return unless @logsize / @hash.size >= MINIMUM_BLOAT_FACTOR

    vacuum
  end

  # Read the database contents from the file into memory.
  def read_from_file
    File.open( @path, 'rb' ) do |f|
      first = f.gets
      raise "Invalid file header" unless first.chomp == HEADER

      bytes = first.size

      while !f.eof?
        command = f.gets
        # If the last line is a partial line, we discard it
        unless command =~ /\n\Z/
          discard_until bytes
          return
        end

        oper, keysize, valsize = command.split ':'
        keysize = keysize.to_i
        valsize = valsize.to_i

        keyd = f.read keysize
        vald = f.read valsize

        if !keyd || !vald
          discard_until bytes
          return
        end

        if keyd.size != keysize || vald.size != valsize
          discard_until bytes
          return
        end

        bytes += command.size
        bytes += keysize
        bytes += valsize

        key = Marshal.load keyd
        val = Marshal.load vald
        @logsize += 1
        case oper
        when 'r' # replace
          @hash[key] = val
        when 'd' # delete
          @hash.delete key
        end
      end
    end
  end

  # Truncate invalid commands found at the end of the database on disk.
  def discard_until bytes
    Log.debug "Incomplete database: #@path, truncating to #{bytes} bytes"
    File.truncate @path, bytes
  end

  # Remove old log entries by rewriting the log.  When the same key is saved to
  # twice, the old value is no longer needed.
  def vacuum
    Log.debug "Vacuuming #{@path.inspect}, has #@logsize entries, only needs #{@hash.size}"
    old_logfile = @logfile
    old_logsize = @logsize
    begin
      temp = @path + ".#$$.tmp"
      @logfile = File.open temp, 'wb'
      @logfile.sync = true
      @logsize = 0
      @logfile.puts HEADER
      @hash.each do |key,val|
        append 'r', key, val
      end
      @logfile.close
      File.rename temp, @path
    ensure
      # Since we're not sure how our caller will handle an exception, make
      # sure that the database file is in a consistent state.  Consider,
      # for example, what would happen if the disk filled up during a
      # vacuum.
      @logfile = old_logfile
      @logsize = old_logsize
    end
    @logfile = File.open @path, 'ab'
  end
end
