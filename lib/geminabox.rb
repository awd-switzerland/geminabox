# encoding: utf-8

# external libraries
require "builder"
require "digest/md5"
require "fileutils"
require "rubygems"
require "rubygems/builder"
require "rubygems/indexer"
require "rubygems/installer"
require "securerandom"
require "sinatra/base"
require "yard"

# internal libraries
require "hostess"



class Geminabox < Sinatra::Base
  include FileUtils

  enable :static, :methodoverride

  set :public_folder, File.join(File.dirname(__FILE__), *%w[.. public])
  set :gems_directory, File.join(File.dirname(__FILE__), *%w[.. data gems])
  set :docs_directory, File.join(File.dirname(__FILE__), *%w[.. data docs])
  set :build_legacy, false
  set :incremental_updates, false
  set :views, File.join(File.dirname(__FILE__), *%w[.. views])
  set :allow_replace, false
  use Hostess

  class << self
    def disallow_replace?
      ! allow_replace
    end

    def fixup_bundler_rubygems!
      return if @post_reset_hook_applied
      Gem.post_reset{ Gem::Specification.all = nil } if defined? Bundler and Gem.respond_to? :post_reset
      @post_reset_hook_applied = true
    end
  end

  autoload :GemVersionCollection, "geminabox/gem_version_collection"

  get '/' do
    @gems = load_gems
    @index_gems = index_gems(@gems)
    erb :index
  end

  get '/atom.xml' do
    @gems = load_gems
    erb :atom, :layout => false
  end

  get '/upload' do
    erb :upload
  end

  get '/reindex' do
    reindex(:force_rebuild)
    redirect url("/")
  end

  get '/docs/:gem' do
    redirect "/docs/#{params[:gem]}/index.html", 303
  end

  get '/docs/:gem/*' do
    generate_docs_if_necessary(params[:gem])
    rest_path = params[:splat].first
    rest_path = "index.html" if rest_path.empty?

    send_file "#{settings.docs_directory}/#{params[:gem]}/#{rest_path}"
  end

  delete '/gems/*.gem' do
    File.delete file_path if File.exists? file_path
    reindex(:force_rebuild)
    redirect url("/")
  end

  post '/upload' do
    return "Please ensure #{File.expand_path(Geminabox.gems_directory)} is writable by the geminabox web server." unless File.writable? Geminabox.gems_directory
    unless params[:file] && (tmpfile = params[:file][:tempfile]) && (name = params[:file][:filename])
      @error = "No file selected"
      return erb(:upload)
    end

    tmpfile.binmode

    Dir.mkdir(File.join(settings.gems_directory, "gems")) unless File.directory? File.join(settings.gems_directory, "gems")

    dest_filename = File.join(settings.gems_directory, "gems", File.basename(name))


    if Geminabox.disallow_replace? and File.exist?(dest_filename)
      existing_file_digest = Digest::SHA1.file(dest_filename).hexdigest
      tmpfile_digest = Digest::SHA1.file(tmpfile.path).hexdigest

      if existing_file_digest != tmpfile_digest
        return error_response(409, "Gem already exists, you must delete the existing version first.")
      else
        return [200, "Ignoring upload, you uploaded the same thing previously."]
      end
    end

    File.open(dest_filename, "wb:binary") do |f|
      while blk = tmpfile.read(65536)
        f << blk
      end
    end
    reindex
    redirect url("/")
  end

private

  def error_response(code, message)
    html = <<HTML
<html>
  <head><title>Error - #{code}</title></head>
  <body>
    <h1>Error - #{code}</h1>
    <p>#{message}</p>
  </body>
</html>
HTML
    [code, html]
  end

  def reindex(force_rebuild = false)
    Geminabox.fixup_bundler_rubygems!
    force_rebuild = true unless settings.incremental_updates
    if force_rebuild
      indexer.generate_index
    else
      begin
        indexer.update_index
      rescue => e
        puts "#{e.class}:#{e.message}"
        puts e.backtrace.join("\n")
        reindex(:force_rebuild)
      end
    end
  end

  def generate_docs_if_necessary(gem)
    generate_docs(gem) unless File.directory?("#{settings.docs_directory}/#{gem}")
  end

  def generate_docs(gem)
    gem_src     = "#{settings.gems_directory}/gems/#{gem}.gem"
    token       = SecureRandom.hex(32)
    tmp_gem     = File.expand_path("tmp/gemdoc_#{token}")
    doc_target  = "#{settings.docs_directory}/#{gem}"
    mkdir_p(tmp_gem)
    mkdir_p(doc_target)
    Gem::Installer.new(gem_src, :unpack => true).unpack(tmp_gem)
    Dir.chdir(tmp_gem) do
      YARD::CLI::Yardoc.run('-o', doc_target)
    end
  end

  def indexer
    Gem::Indexer.new(settings.gems_directory, :build_legacy => settings.build_legacy)
  end

  def file_path
    File.expand_path(File.join(settings.gems_directory, *request.path_info))
  end

  def load_gems
    %w(specs prerelease_specs).inject(GemVersionCollection.new){|gems, specs_file_type|
      specs_file_path = File.join(settings.gems_directory, "#{specs_file_type}.#{Gem.marshal_version}.gz")
      if File.exists?(specs_file_path)
        gems |= Geminabox::GemVersionCollection.new(Marshal.load(Gem.gunzip(Gem.read_binary(specs_file_path))))
      end
      gems
    }
  end

  def index_gems(gems)
    Set.new(gems.map{|gem| gem.name[0..0].downcase})
  end

  helpers do
    def spec_for(gem_name, version)
      spec_file = File.join(settings.gems_directory, "quick", "Marshal.#{Gem.marshal_version}", "#{gem_name}-#{version}.gemspec.rz")
      Marshal.load(Gem.inflate(File.read(spec_file))) if File.exists? spec_file
    end
  end
end
