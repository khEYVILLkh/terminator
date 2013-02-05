#!/usr/bin/env ruby



# Author: Peter Schroeter (peter.schroeter@rightscale.com)
#
require 'rubygems'
require 'ruby-debug'
require 'rest_connection'
require 'time'
require 'logger'
require 'trollop'

opts = Trollop::options do
  version "0.1.0"
  banner <<-EOS
Delete old volumes and snapshots across all clouds. Will delete any volumes
not in use, will delete any old snapshots other than base_image snapshots.
Have "save" in the description, nickname, or in a tag to prevent deletion

USAGE:
  EOS
  opt :debug, "Turn on debug output", :default => false
  opt :volumes_age, "Delete volumes older than X days", :type => :integer, :default => 7
  opt :snapshots_age, "Delete snapshots older than X days", :type => :integer, :default => 30
  opt :dry_run, "Don't execute final calls, just print what you would do", :default => true
  opt :cloud, "Which cloud to run against", :type => :string, :default => 'amazon'
  opt :awskey, "AWS key", :type => :string, :default => ''
  opt :awssecret, "AWS secret", :type => :string, :default => ''
end

@logger = Logger.new(STDOUT)
@logger.level = opts[:debug] ? Logger::DEBUG : Logger::INFO
me = `whoami`
ENV['REST_CONNECTION_LOG'] = "/tmp/rest_connection_#{me}.log"
puts "Logging rest connection calls to: #{ENV['REST_CONNECTION_LOG']}"

SECONDS_IN_DAY = 3600*24
# save and do_not should cover human intervention cases
# install refers to "SQL2K8R2-Install-Media" volume, which silver team needs
# to build images
SAFE_WORDS = ["save", "install", "do_not", "do not", "media", "base_image"]
EC2_REGIONS = [
  [6, 'us-west-2'],
  [3, 'us-west-1'],
  [1, 'us-east-1'],
  [2, 'eu-west-1'],
  [4, 'ap-southeast-1'],
  [5, 'ap-northeast-1'],
  [7, 'sa-east-1']
]

def handle_delete(item, dry_run)
  if dry_run
    delete_msg = "WOULD DELETE"
  else
    delete_msg = "DELETING"
  end

  @logger.info("#{delete_msg} #{item.href} (#{item.nickname})")
  unless dry_run
    begin
      item.destroy
      @logger.info("Deletion successful")
    rescue Exception => e
      @logger.info("Unable to delete item: #{item.rs_id}")
      @logger.info("Exception occurred: #{e.inspect}")
    end
  end
end

def delete_items(items, age_seconds, api_15, dry_run, &blk)
  items.each do |i|
    unless api_15
      i.status = i.aws_status
      i.resource_uid = i.aws_id
      # Snapshots don't have created at field for api 1.0
      # but volumes do
      i.created_at ||= i.aws_started_at
    end
    # Google doesn't return created_at field, fall back to updated_at
    create_time = i.created_at||i.updated_at

    elapsed_secs = (Time.now - Time.parse(create_time)).to_i
    @logger.debug("RS_ID:#{i.rs_id} RESOURCE_ID:#{i.resource_uid} NICKNAME:#{i.nickname} STATE:#{i.status} AGE(HRS):#{elapsed_secs/3600}")
    if elapsed_secs < age_seconds 
      @logger.debug("Skipping #{i.resource_uid}, too young")
    elsif blk.call(i)
      handle_delete(i, dry_run)
    end
  end
end

def delete_volumes(volumes, age_seconds, api_15 = false, dry_run = false)
  delete_items(volumes, age_seconds, api_15, dry_run) do |i|
    if i.status == "available"
      if SAFE_WORDS.any? { |w| i.nickname.to_s.downcase.include?(w) } or 
        SAFE_WORDS.any? { |w| i.description.to_s.downcase.include?(w) }
        @logger.debug("Skipping #{i.resource_uid}, nickname or description contain a safe word")
        false
      elsif i.nickname.to_s.downcase =~ /^ubuntu|^centos|^base_image/
        @logger.debug("Skipping #{i.resource_uid}, appears to be a base image volume") 
        false
# commented out for slowness for now
#      elsif i.tags.any? { |tag| SAFE_WORDS.any? {|w| tag.downcase.include?(w) } }
#        @logger.debug("Skipping #{i.resource_uid} tags contain a safe word")
#        false
      else
        true
      end
    else
      false
    end
  end
end

def delete_snapshots(snapshots, age_seconds, api_15 = false, dry_run = false)
  delete_items(snapshots, age_seconds, api_15, dry_run) do |i|
    if SAFE_WORDS.any? { |w| i.nickname.to_s.downcase.include?(w) } or 
      SAFE_WORDS.any? { |w| i.description.to_s.downcase.include?(w) }
      @logger.debug("Skipping #{i.resource_uid}, nickname or description contain a safe word")
      false
    elsif i.nickname.to_s.downcase =~ /^ubuntu|^centos|^base_image/
      @logger.debug("Skipping #{i.resource_uid}, appears to be a base image snapshot") 
      false
    else
      true
    end
  end
end

def getAWSSnapshots(region, key, secret)
	raw = `/opt/ec2-api-tools-1.6.4/bin/ec2-describe-snapshots -o self -O #{key} -W #{secret} --show-empty-fields --region #{region}`
	snapshot=[]
	raw.split(/\n/).each do |l|
		a = l.split(/\t+/)
		snapshot << {"SnapshotId"=>a[1], "VolumeId"=>a[2], "Status"=>a[3], "StartTime"=>a[4], "Progress"=>a[5], "OwnerId"=>a[6], "VolumeSize"=>a[7], "Description"=>a[8]}
	end
	return snapshot
end

def getAWSVolumes(region, key, secret)
	raw = `/opt/ec2-api-tools-1.6.4/bin/ec2-describe-volumes -O #{key} -W #{secret} --show-empty-fields --region #{region}`
	volume=[]
	raw.split(/\n/).each do |l|
		a = l.split(/\t+/)
		volume << {"VolumeId"=>a[1], "Size"=>a[2], "SnapshotId"=>a[3], "AvailabilityZone"=>a[4], "Status"=>a[5], "CreateTime"=>a[6], "VolumeType"=>a[7], "IOps"=>a[8]}
	end
	return volume
end

def getAWSImageBlockDevices(region, key, secret)
	raw = `/opt/ec2-api-tools-1.6.4/bin/ec2-describe-images -O #{key} -W #{secret} --show-empty-fields --region #{region}`
	bd=[]
	raw.split(/\n/).each do |l|
		a = l.split(/\t+/)
		if a[0] =~ /BLOCKDEVICEMAPPING/
			bd << {"Type"=>a[0], "DeviceName"=>a[1], "SnapshotId"=>a[3], "Size"=>a[4]}
		end
	end
	return bd
end

def getImages(region, key, secret)
	raw = `/opt/ec2-api-tools-1.6.4/bin/ec2-describe-images -O #{key} -W #{secret} --show-empty-fields --region #{region}`
	image=[]
	raw.split(/\n/).each do |l|
		a = l.split(/\t+/)
		if a[0] =~ /IMAGE/
			image << {"Type"=>a[0], "ImageId"=>a[1], "Name"=>a[2], "Owner"=>a[3], "State"=>a[4], "Accessibility"=>a[5], "ProductCodes"=>a[6], "Architecture"=>a[7], "ImageType"=>a[8], "KernelId"=>a[9], "RamdiskId"=>a[10], "Platform"=>a[11], "RootDeviceType"=>a[12], "VirtualizationType"=>a[13], "Hypervisor"=>a[14]}
		end
	end
	return image
end
###### Begin Main #######

puts "Starting run, skipping any volumes and snapshots containing words: #{SAFE_WORDS.join(' ')}"


=begin
EC2_REGIONS.each do |cloud_id, name|
  @logger.info "========== #{name} (volumes) ========="
  vols = Ec2EbsVolume.find_by_cloud_id(cloud_id.to_i)
  delete_volumes(vols, SECONDS_IN_DAY * opts[:volumes_age], api_15 = false, opts[:dry_run])
end
EC2_REGIONS.each do |cloud_id, name|
  @logger.info "========== #{name} (snapshots) ========="
  snapshots = Ec2EbsSnapshot.find_by_cloud_id(cloud_id.to_i)
  delete_snapshots(snapshots, SECONDS_IN_DAY * opts[:snapshots_age], api_15 = false, opts[:dry_run])
end

clouds_with_volumes = Cloud.find_all.select {|c| c.links.any? {|l| l['rel'] =~ /volume/}}
clouds_with_volumes.each do |cloud|
  @logger.info "========== #{cloud.name} (volumes) ========="
  vols = McVolume.find_all(cloud.cloud_id.to_i)
  delete_volumes(vols, SECONDS_IN_DAY * opts[:volumes_age], api_15 = true, opts[:dry_run])
end
clouds_with_snapshots = Cloud.find_all.select {|c| c.links.any? {|l| l['rel'] =~ /snapshot/}}
clouds_with_snapshots.each do |cloud|
  @logger.info "========== #{cloud.name} (snapshots) ========="
  snapshots = McVolumeSnapshot.find_all(cloud.cloud_id.to_i)
  delete_snapshots(snapshots, SECONDS_IN_DAY * opts[:snapshots_age], api_15 = true, opts[:dry_run])
end
=end

=begin
csx302 = Cloud.find_all.select {|c| c['name'].include?("CS 3.0.2 Eng - XenServer")}
csx302.each do |cloud|
  @logger.info "========== #{cloud.name} (volumes) ========="
  vols = McVolume.find_all(cloud.cloud_id.to_i)
  delete_volumes(vols, SECONDS_IN_DAY * opts[:volumes_age], api_15 = true, opts[:dry_run])
end
csx302.each do |cloud|
  @logger.info "========== #{cloud.name} (snapshots) ========="
  snapshots = McVolumeSnapshot.find_all(cloud.cloud_id.to_i)
  delete_snapshots(snapshots, SECONDS_IN_DAY * opts[:snapshots_age], api_15 = true, opts[:dry_run])
end
#!/usr/bin/env ruby
=end

snapshot = []
volume = []
blockdevice = []
if opts[:cloud] != 'amazon'
  opts[:cloud].split(/,/).each do |cloud_id|
    cloud = Cloud.find(cloud_id.to_i)
    puts "Loading data for #{cloud.name}"
    cloud.href =~ /\/api\/clouds\/([0-9]+)/
    cloud_id = $1
    snapshots = McVolumeSnapshot.find_all(cloud_id)
    volumes = McVolume.find_all(cloud_id)

    #Delete Volumes
    vols = McVolume.find_all(cloud_id)
      @logger.info "========== #{cloud.name} (volumes) ========="
      delete_volumes(vols, SECONDS_IN_DAY * opts[:volumes_age], api_15 = true, opts[:dry_run])
    #Delete Snapshots
    snapshots = McVolumeSnapshot.find_all(cloud_id)
      @logger.info "========== #{cloud.name} (snapshots) ========="
      delete_snapshots(snapshots, SECONDS_IN_DAY * opts[:snapshots_age], api_15 = true, opts[:dry_run])
  end
end

if opts[:cloud] == 'amazon'
  EC2_REGIONS.each do |cloud_id, name|
    puts "Loading AWS data for #{name}"
    snapshot.concat(getAWSSnapshots(name, opts[:awskey], opts[:awssecret]))
    volume.concat(getAWSVolumes(name, opts[:awskey], opts[:awssecret]))
    blockdevice.concat(getAWSImageBlockDevices(name, opts[:awskey], opts[:awssecret]))
  end



  #Get a list of snapshots that have are in use in templates
  templateSnapshots = []
  snapshot.select {|s| blockdevice.any? { |b| b["SnapshotId"] == s["SnapshotId"]}}.each do |line| 
        templateSnapshots << line
        snapshot.delete_if { |d| d==line }
  end
  puts "#{templateSnapshots.count} snapshots are associated with images and will NOT be deleted"

  #Get a list of volumes that have snapshots associated with a template
  templateVolumes = []
  volume.select {|v| snapshot.any? { |s| s["VolumeId"] == v["VolumeId"] and blockdevice.any? { |b| b["SnapshotId"] == s["SnapshotId"]}}}.each do |line| 
        templateVolumes << line
        volume.delete_if { |d| d==line }
  end
  puts "#{templateVolumes.count} volumes are associated with images and will NOT be deleted"

  #Delete Volumes
  EC2_REGIONS.each do |cloud_id, name|
    @logger.info "========== #{name} (volumes) ========="
    vols = Ec2EbsVolume.find_by_cloud_id(cloud_id.to_i).select{ |v| volume.any? { |v2| v2["VolumeId"] == v.aws_id}}
    delete_volumes(vols, SECONDS_IN_DAY * opts[:volumes_age], api_15 = false, opts[:dry_run])
  end
  #Delete Snapshots
  EC2_REGIONS.each do |cloud_id, name|
    @logger.info "========== #{name} (snapshots) ========="
    snapshots = Ec2EbsSnapshot.find_by_cloud_id(cloud_id.to_i).select{ |s| snapshot.any? { |s2| s2["SnapshotId"] == s.aws_id } } 
    delete_snapshots(snapshots, SECONDS_IN_DAY * opts[:snapshots_age], api_15 = false, opts[:dry_run])
  end
end
