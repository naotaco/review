#
# Copyright (c) 2018 Masanori Kado, Masayoshi Takahashi, Kenshi Muto
#
# This program is free software.
# You can distribute or modify this program under the terms of
# the GNU LGPL, Lesser General Public License version 2.1.
# For details of the GNU LGPL, see the file "COPYING".

require 'fileutils'
require 'optparse'
require 'net/http'
require 'tempfile'
require 'review'

module ReVIEW
  class Init
    def self.execute(*args)
      new.execute(*args)
    end

    def initialize
      @template = 'review-jsbook'
      @logger = ReVIEW.logger
      @review_dir = File.dirname(File.expand_path('..', __dir__))
    end

    def execute(*args)
      initdir = parse_options(args)

      generate_dir(initdir) do |dir|
        generate_catalog_file(dir)
        generate_sample(dir)
        generate_images_dir(dir)
        generate_cover_image(dir)
        generate_layout(dir)
        generate_style(dir)
        generate_texmacro(dir)
        generate_config(dir)
        generate_locale(dir) if @locale
        generate_rakefile(dir)
        generate_gemfile(dir)
        generate_doc(dir) unless @without_doc
        download_and_extract_archive(dir, @archive) if @archive
      end
    end

    def parse_options(args)
      opts = OptionParser.new
      opts.version = ReVIEW::VERSION
      opts.banner = "Usage: #{File.basename($PROGRAM_NAME)} [option] dirname"
      opts.on('-h', '--help', 'print this message and quit.') do
        puts opts.help
        exit 0
      end
      opts.on('-f', '--force', 'generate files (except *.re) if directory has already existed.') do
        @force = true
      end
      opts.on('-l', '--locale', 'generate locale.yml file.') do
        @locale = true
      end
      opts.on('--latex-template name', 'specify LaTeX template name. (default: review-jsbook)') do |tname|
        @template = tname
      end
      opts.on('', '--epub-version VERSION', 'define EPUB version.') do |version|
        @epub_version = version
      end
      opts.on('', '--without-doc', "don't generate doc files.") do
        @without_doc = true
      end
      opts.on('-p', '--package archivefile', 'extract from local or network archive.') do |archive|
        @archive = archive
      end

      begin
        opts.parse!(args)
      rescue OptionParser::ParseError => err
        @logger.error err.message
        $stderr.puts opts.help
        exit 1
      end

      if args.empty?
        $stderr.puts opts.help
        exit 1
      end

      initdir = File.expand_path(args[0])

      initdir
    end

    def generate_dir(dir)
      if File.exist?(dir) && !@force
        @logger.error "#{dir} already exists."
        exit 1
      end
      FileUtils.mkdir_p dir
      yield dir
    end

    def generate_sample(dir)
      unless @force
        File.write("#{dir}/#{File.basename(dir)}.re", '= ')
      end
    end

    def generate_layout(dir)
      FileUtils.mkdir_p dir + '/layouts'
    end

    def generate_catalog_file(dir)
      File.open(dir + '/catalog.yml', 'w') do |file|
        file.write <<-EOS
PREDEF:

CHAPS:
  - #{File.basename(dir)}.re

APPENDIX:

POSTDEF:

EOS
      end
    end

    def generate_images_dir(dir)
      FileUtils.mkdir_p(dir + '/images')
    end

    def generate_cover_image(dir)
      FileUtils.cp(@review_dir + '/samples/sample-book/src/images/cover.jpg',
                   dir + '/images/')
    end

    def generate_config(dir)
      today = Time.now.strftime('%Y-%m-%d')
      content = File.read(@review_dir + '/doc/config.yml.sample', encoding: 'utf-8')
      content.gsub!(/^#\s*coverimage:.*$/, 'coverimage: cover.jpg')
      content.gsub!(/^#\s*date:.*$/, "date: #{today}")
      content.gsub!(/^#\s*history:.*$/, %Q(history: [["#{today}"]]))
      content.gsub!(/^#\s*texstyle:.*$/, 'texstyle: reviewmacro')
      content.gsub!(/^(#\s*)?stylesheet:.*$/, %Q(stylesheet: ["style.css"]))
      if @epub_version.to_i == 2
        content.gsub!(/^#.*epubversion:.*$/, 'epubversion: 2')
        content.gsub!(/^#.*htmlversion:.*$/, 'htmlversion: 4')
      end
      File.open(File.join(dir, 'config.yml'), 'w') { |f| f.write(content) }
    end

    def generate_style(dir)
      FileUtils.cp @review_dir + '/samples/sample-book/src/style.css', dir
    end

    def generate_texmacro(dir)
      texmacrodir = dir + '/sty'
      FileUtils.mkdir_p texmacrodir
      tdir = File.join(@review_dir, '/templates/latex', @template)
      @logger.error "#{tdir} not found." unless File.exist?(tdir)
      FileUtils.cp Dir.glob(tdir + '/*.*'), texmacrodir
    end

    def generate_rakefile(dir)
      FileUtils.mkdir_p dir + '/lib/tasks'

      File.open(dir + '/Rakefile', 'w') do |file|
        file.write <<-EOS
Dir.glob('lib/tasks/*.rake').each do |file|
  load(file)
end
EOS
      end

      FileUtils.cp(@review_dir + '/samples/sample-book/src/Rakefile',
                   dir + '/lib/tasks/review.rake')
    end

    def generate_locale(dir)
      FileUtils.cp @review_dir + '/lib/review/i18n.yml', dir + '/locale.yml'
    end

    def generate_gemfile(dir)
      File.open(dir + '/Gemfile', 'w') do |file|
        file.write <<-EOS
source 'https://rubygems.org'

gem 'rake'
gem 'review', '#{ReVIEW::VERSION}'
EOS
      end
    end

    def generate_doc(dir)
      docdir = dir + '/doc'
      FileUtils.mkdir_p docdir
      md_files = Dir.glob(@review_dir + '/doc/*.md').map.to_a
      FileUtils.cp md_files, docdir
    end

    def download_and_extract_archive(dir, filename)
      begin
        require 'zip'
      rescue LoadError
        @logger.error 'extracting needs rubyzip.'
        exit 1
      end

      if filename =~ %r{\Ahttps?://}
        begin
          @logger.info "Downloading from #{filename}"
          zipdata = Net::HTTP.get(URI.parse(filename))
        rescue StandardError => err
          @logger.error "Failed to download #{filename}: #{err.message}"
          exit 1
        end

        begin
          f = Tempfile.new('reviewinit')
          zipfilename = f.path
          f.write zipdata
          f.close

          extract_archive(dir, zipfilename, filename)
        ensure
          f.unlink
        end
      else
        unless File.readable?(filename)
          @logger.error "Failed to open #{filename}"
          exit 1
        end
        extract_archive(dir, filename, filename)
      end
    end

    def extract_archive(dir, filename, originalfilename)
      made = nil
      begin
        Zip::File.open(filename) do |zip|
          zip.each do |entry|
            fname = entry.name.gsub('\\', '/')
            if fname =~ /__MACOSX/ || fname =~ /\.DS_Store/
              next
            end

            if fname =~ %r{\A/} || fname =~ /\.\./ # simple fool proof
              made = nil
              break
            end

            # `true' means override
            entry.extract(File.join(dir, fname)) { true }
          end
          made = true
        end
        raise Zip::Error unless made
      rescue Zip::Error => err
        @logger.error "#{originalfilename} seems invalid or broken zip file: #{err.message}"
      end
    end
  end
end
