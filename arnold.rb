#!/usr/bin/env ruby

require 'rubygems'
require 'rest_connection'
require 'thread'
require 'time'
require 'terminal-table/import'

@safewords = ["monkey", "save", "slave"]
@tag_prefix = "terminator:discovery_time="
@debug = true
@expiration = 24

@table = [['Server', 'Action', 'State', 'Cloud']]

EC2_REGIONS = [
  [0, 'null'],
  [1, 'us-east-1'],
  [2, 'eu-west-1'],
  [3, 'us-west-1'],
  [4, 'ap-southeast-1'],
  [5, 'ap-northeast-1'],
  [6, 'us-west-2'],
  [7, 'sa-east-1']
]


me = `whoami`
ENV['REST_CONNECTION_LOG'] = "/tmp/rest_connection_#{me}.log"

def instanceTerminator()
    t1 = nil
  #  awsservers = Server.find_all()
    t=[]
    mcservers = McServer.find_all()
    mcservers.each do |server|
      if t.count >= 50
        t.each do |i|
          begin
            i.join
          rescue
            puts "Thread Error" if @debug
          end
        end
        t=[]
      end
      
      t.push(Thread.new {inspectServer(server, false)})
    end

    servers = Server.find_all()
    servers.each do |server|
      if t.count >= 50
        t.each do |i|
          begin
            i.join
          rescue
            puts "Thread Error" if @debug
          end
        end
        t=[]
      end
      
      t.push(Thread.new {inspectServer(server, true)})
  #    inspectServer(server, true)
    end

end

#t.each do |i|
#	begin
#		i.join
#	rescue
#		puts "Thread Error" if @debug
#	end
#end

#end

def inspectServer(server, api10)

  cloud='unknown'

  #catch strange errors
  server.name = server.nickname if api10
  if !server.name
    puts "#{server} #{server.href} has no name!" if @debug
    return 1
  end

  begin
    state = server.state
  rescue
    state = "Unknown"
  end

  if server.state.to_s =~ /(terminated|stopped|inactive)/
    puts "#{server.name} #{server.href} is not running, skipping" if @debug
    cleanTags(server, api10)
    return 1
  end
  if @safewords.any?{|w| server.name.downcase.include?(w)}
    puts "#{server.name} #{server.href} includes safe word, skipping" if @debug
    @table << [server.name, "Protected by SafeWord", state, cloud]
    return 1
  end

  settings = server.settings

  if (not api10 and not settings['actions'].include?("rel"=>"terminate")) || (api10 and settings['locked'])
    puts "#{server.name} #{server.href} is locked, skipping"  if @debug
    @table << [server.name, "Locked", state, cloud]
    return 1
  end

  href = server.current_instance_href
  href =~ /(\/api\/clouds\/[0-9]+)/
  cloud_href = $1
  cloud = Cloud.find(cloud_href).name unless api10
  cloud = "AWS #{EC2_REGIONS[server.cloud_id][1]}" if api10
  expiration =  checkExpiration(server, href, api10)
  if expiration == "expired" and server.state.to_s =~ /(running|operational)/
    puts "#{server.name.to_s} #{server.href} is expired. Terminating it now"  if @debug
    terminateInstance(server, cloud, api10)
    @table << [server.name, "Terminating", state, cloud]
    return 0
  elsif expiration == "untagged"
    stampExpiration(server, href, api10)
    @table << [server.name, "Tagged", state, cloud]
    return 0
  elsif expiration == "fresh"
    @table << [server.name, "Fresh", state, cloud]
    return 0
  end
  @table << [server.name, "Unfiltered", state, cloud]
  return 1
      

  
end

def terminateInstance(server, cloud, api10)
  server.stop if api10
  server.terminate unless api10
  cleanTags(server, api10)
  puts "#{server.name.to_s} #{server.href} has been terminated" if @debug
  `echo "Be sure to lock the server or put save somewhere in the nickname to prevent pwnage from the terminator" | mail -s "#{server.name} from #{cloud} has been destroyed by Terminator2901" white.sprint@rightscale.com -c silver.sprint@rightscale.com` 
  #`echo "Be sure to lock the server or put save somewhere in the nickname to prevent pwnage from the terminator" | mail -s "#{server.name} from #{cloud} has been destroyed by Terminator2901" bill.rich@rightscale.com` 
end

def checkExpiration(object, href, api10)
  tags = Tag.search_by_href(href) if api10
  tags = McTag.search_by_href(href)[0]['tags'] unless api10
  tags.each do |tag|
    if tag['name'].include?(@tag_prefix)
      tag_timestamp = Time.parse(tag['name'].split("=").last)
      if tag_timestamp + @expiration * 60 * 60 < Time.now
        return "expired"
      else
        return "fresh"
      end
    end
  end
  return "untagged"
end

def stampExpiration(object, href, api10)
  tag_contents = @tag_prefix + Time.now.to_s
  puts "#{object.name.to_s} #{object.href} has no tag, setting it now" if @debug
  Tag.set(href, [tag_contents]) if api10
  McTag.set(href, [tag_contents]) unless api10
end

def cleanTags(object, api10)
  tags = Tag.search_by_href(object.href) if api10
  tags = McTag.search_by_href(object.href)[0]['tags'] unless api10
  tags.each do |tag|
    if tag['name'].include?(@tag_prefix)
      puts "Cleaning up tag for #{object.name} #{object.href} " if @debug
      Tag.unset(object.href,[tag['name'].to_s]) if api10
      McTag.unset(object.href,[tag['name'].to_s]) unless api10
    end
  end
end

instanceTerminator()
puts table(*@table)
