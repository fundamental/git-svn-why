require 'open3'



input_name = "the-repo-to-clone"
input_repo = "http://the-path-in-your/svn/repo/to/clone"
input_base = "http://the-path-in-your/svn/"


$input_repo = input_repo

class Extern
  attr_accessor :src,
                :dst,
                :src_offset,
                :dst_offset
  def initialize(src, dest, src_offset, dst_offset)
    src_offset = src_offset[0..-2] if src_offset[-1] == "/"
    dst_offset = dst_offset[0..-2] if dst_offset[-1] == "/"
    @src        = src
    @dst        = dest
    @src_offset = src_offset
    @dst_offset = dst_offset
  end
end

class Repository
  attr_accessor :url, :file_name, :age
  def initialize(url, file_name)
    @url       = url
    @file_name = file_name
    @age       = 1
  end

  def to_s()
    "#<Repository: url=#{@url}, nick=#{@file_name}, age=#{@age}>"
  end
end



#Let's parse those results

$repositories = []
$externs      = []

$src_unique = []
$src_repos  = []
$dest_paths = []
$offsets    = []

def incr_nick(url, nick)
  (0..10).each do |i|
    nn = nick
    nn = nick+i.to_s if i!=0
    good = true
    $repositories.each do |r|
      if(r.file_name == nn && r.url != url)
        good = false
      end
    end
    return nn if good
  end
  return "INVALID_NICK"
end

def repo_normalize(repo)

  #Special handling for paths off the input repo
  if(repo[0..$input_repo.length-1] == $input_repo)
    src  = "../"
    nick = ".."
    off  = repo[$input_repo.length..-1]
    return src, nick, off
  end

  #All paths are assumed to end in a "/"
  #
  # TODO fix the origin of this problem as individual files can and *ARE*
  # externed (why, why is this done?)
  repo += "/" if(repo[-1] != "/")

  pat_trunk  = /(.*)\/trunk\/(.*)/
  pat_branch = /(.*)\/branches\/([^\/]*)\/(.*)/
  pat_tag    = /(.*)\/tags\/([^\/]*)\/(.*)/

  tm   = pat_trunk.match  repo
  bm   = pat_branch.match repo
  gm   = pat_tag.match    repo

  #The nickname of the repo is the last path item
  #If that last path item is of the format of a version identifier then we
  #likely have encountered "project/x.y.z" , thus making "project-x.y.z" a good
  #nickname

  nick = repo.split("/")[-1]

  if(/^[0-9\.]*$/.match(nick) || /^201[123456789][_-]/.match(nick))
    sp = repo.split("/")
    nick = sp[-2] + "-" + sp[-1]
  end


  #Initially we are at no offset within the repository, but if we can identify
  #that we're in a subfolder, then the file getting externed from the original
  #path will be at an offset e.g.
  # input              = /foo/bar/xxx/trunk/blam/baz -> 
  # repository url     = /foo/bar/xxx/trunk
  # nickname           = xxx
  # offset within repo = "blam/baz"

  src  = repo
  off  = ""
  if(tm)
    nick = tm[1].split("/")[-1]
    src  = tm[1] + "/trunk/"
    off  = tm[2]
  elsif(bm)
    nick = bm[1].split("/")[-1]+"-"+bm[2]
    src  = bm[1] + "/branches/" + bm[2] + "/"
    off  = bm[3]
  elsif(gm)
    nick = gm[1].split("/")[-1]+"-"+gm[2]
    src  = gm[1] + "/tags/" + gm[2] + "/"
    off  = gm[3]
  end
  nick = incr_nick(src, nick)
  return src, nick, off
end

def valid_repo_url(url)
  _, svn_exist, _ = Open3.capture3("svn ls #{url} --depth empty")
  if(/E200009:/.match(svn_exist))
    puts "WARNING: #{url} does not exist in SVN"
    puts "         FIX YOUR BROKEN EXTERNS"
    return false
  else
    #puts "Found #{url} in SVN"
    return true
  end
end

def add_extern(src, dest, offset)
  (src_norm, src_nick, src_off) = repo_normalize(src)
  (dst_norm, dst_nick, dst_off) = repo_normalize(dest)

  return if !valid_repo_url(src_norm)

  if(!$src_unique.include? src_norm)
    $src_unique   << src_norm
    $repositories << Repository.new(src_norm, src_nick)
  end
  $externs    << Extern.new(src_nick, dst_nick, src_off, dst_off)

  $src_repos  << src
  $dest_paths << dest
  $offsets    << src_off
end

def parse_results(res, root, base)
  newdir = /(.*) - (.*) (.*)$/
  newext = /(.*) (.*)/
  current_dir = "."
  res.each_line do |ln|
    ln = ln.strip
    ndm = newdir.match(ln)
    nem = newext.match(ln)
    #puts "---------------------------------------"
    #puts ln

    if(ndm)
      #puts "new directory = #{ndm[1]}"
      current_dir = ndm[1]
      current_dir += "/" if current_dir[-1] != "/"
      #puts "<#{ln}>"
      src_path = ndm[2]
      dst_path = ndm[3]
      if(/http:/.match ndm[3]) #Who the hell knows why this can even happen?
        src_path = ndm[3]
        dst_path = ndm[2]
      end
      if(src_path[0] == "^")
        src_path = base+src_path[2..-1]
      end
      #puts "src_path1 = #{src_path}"
      #puts "dst_path1 = #{dst_path}"
      add_extern(src_path, current_dir+dst_path, "")
    elsif(nem)
      #puts nem[1]
      #puts current_dir+"/"+nem[2]
      src_path = nem[1]
      dst_path = nem[2]
      if(/http:/.match nem[2]) #Who the hell knows why this can even happen?
        src_path = nem[2]
        dst_path = nem[1]
      end
      if(src_path[0] == "^")
        src_path = base+src_path[2..-1]
      end
      #puts "src_path2 = #{src_path}"
      add_extern(src_path, current_dir+dst_path, "")
    end
  end
end

#results = `svn propget svn:externals -R #{repo}`
$repositories << Repository.new(input_repo, "..")
#parse_results(results, ".", base)

#puts $src_repos.sort

ind = 0
$repositories.each_with_index do |rt, i|
  #puts ""
  #puts rt
  puts("Checking for recursive dependencies (#{i}/#{$repositories.length})...")
  res = `svn propget svn:externals -R #{rt.url}`
  parse_results(res, rt, input_base)
end

$repositories.each_with_index do |rt, i|
  puts "Checking repo age (max 50 commits) (#{i}/#{$repositories.length})..."
  #id = `svn log #{rt.url} -rHEAD:1 --limit=50 | tac | grep -m 1 '^\(r\)[0-9]\{1,\}' | cut -f 1 -d " " | tail -c +2`
  id = `svn log #{rt.url} -rHEAD:1 --limit=50 | tac | grep -m 1 ^r[0-9] | cut -f 1 -d " " | tail -c +2`.strip
  rt.age = id.to_i if id.to_i > 0
end

#puts $src_repos.sort
#puts $src_repos.length

begin
  r = $repositories[0]
  `git svn clone -r#{r.age}:HEAD #{r.url} #{input_name}`
  Dir.chdir input_name
  `mkdir .git_externals`
  Dir.chdir ".git_externals"
end

puts "Cloning #{$repositories.length-1} Repositories..."
threads = []
$repositories[1..-1].each do |r|
  puts "git svn clone -r#{r.age}:HEAD #{r.url} #{r.file_name}"
  threads << Thread.new {`git svn clone -r#{r.age}:HEAD #{r.url} #{r.file_name}`}
  if(threads.length > 8)
    threads.each do |t|
      t.join
    end
    threads = []
  end
end
threads.each do |t|
  t.join
end

puts "Applying #{$externs.length} Externs..."
$externs.each do |e|
  dir = `pwd`.strip
  puts "ln -s #{dir}/#{e.src}/#{e.src_offset} #{e.dst}/#{e.dst_offset}"
  `ln -s #{dir}/#{e.src}/#{e.src_offset} #{e.dst}/#{e.dst_offset}`
end
