# frozen_string_literal: true

require 'shellwords'

module Nest
  # Manage ZFS boot environments
  class Beadm
    include Nest::CLI

    def initialize
      @current_fs = %x(zfs list -H -o name `findmnt -n -o SOURCE /`).chomp
      raise '/ is not a ZFS boot environment' unless @current_fs =~ %r{^(([^/]+).*/ROOT)/([^/]+)$}

      @be_root = Regexp.last_match(1)
      @zpool = Regexp.last_match(2)
      @current_be = Regexp.last_match(3)
    end

    def list
      `zfs list -H -o name -r #{@be_root}`.lines.reduce([]) do |bes, filesystem|
        if filesystem.chomp =~ %r{^#{Regexp.escape(@be_root)}/([^/]+)$}
          bes << Regexp.last_match(1)
        else
          bes
        end
      end
    end

    def current
      @current_be
    end

    def active
      raise 'zpool bootfs does not look like a boot environment' unless `zpool get -H -o value bootfs #{@zpool}` =~ %r{^#{Regexp.escape(@be_root)}/([^/]+)$}

      Regexp.last_match(1)
    end

    def create(name)
      if name !~ /^[a-zA-Z0-9][a-zA-Z0-9_:.-]*$/
        logger.fatal "'#{name}' is not a valid boot environment name"
        return false
      end

      if list.include? name
        logger.fatal "Boot environment '#{name}' already exists"
        return false
      end

      logger.info "Creating boot environment '#{name}' from '#{@current_be}'"

      snapshot = "beadm-clone-#{@current_be}-to-#{name}"
      raise 'Failed to create snapshots for cloning' unless cmd.run!("sudo zfs snapshot -r #{@current_fs}@#{snapshot}").success?

      `zfs list -H -o name,mountpoint -r #{@current_fs}`.lines.each do |line|
        (fs, mountpoint) = line.chomp.split("\t")
        clone_fs = "#{@be_root}/#{name}#{fs.sub(/^#{Regexp.escape(@current_fs)}/, '')}"
        if cmd.run!("sudo zfs clone -o canmount=noauto -o mountpoint=#{mountpoint.shellescape} #{fs}@#{snapshot} #{clone_fs}").failure?
          cmd.run "sudo zfs destroy -R #{@current_fs}@#{snapshot}"
          raise 'Failed to clone snapshot. Manual cleanup may be requried.'
        end
      end

      logger.success "Created boot environment '#{name}'"
      true
    end

    def destroy(name)
      if name == @current_be
        logger.fatal 'Cannot destroy the active boot environment'
        return false
      end

      destroy_be = "#{@be_root}/#{name}"

      unless system "zfs list #{destroy_be.shellescape} > /dev/null 2>&1"
        logger.fatal "Boot environment '#{name}' does not exist"
        return false
      end

      logger.info "Destroying boot environment '#{name}'"

      raise 'Failed to destroy the boot environment' unless cmd.run!("sudo zfs destroy -r #{destroy_be}").success?

      `zfs list -H -o name -t snapshot -r #{@be_root}`.lines.map(&:chomp).each do |snapshot|
        next unless snapshot =~ /@beadm-clone-(#{Regexp.escape(name)}-to-.*|.*-to-#{Regexp.escape(name)})$/
        raise 'Failed to destroy snapshot. Manual cleanup may be required.' unless cmd.run!("sudo zfs destroy #{snapshot}").success?
      end

      logger.warn "/mnt/#{name} exists and couldn't be removed" if Dir.exist?("/mnt/#{name}") && cmd.run!("sudo rmdir /mnt/#{name}").failure?

      logger.success "Destroyed boot environment '#{name}'"
      true
    end

    def mount(name)
      mount_be = "#{@be_root}/#{name}"

      filesystems = `zfs list -H -o name,mountpoint -r #{mount_be.shellescape} 2>/dev/null`.lines.each_with_object({}) do |line, fss|
        (fs, mountpoint) = line.chomp.split("\t")
        mountpoint = '' if mountpoint == '/'
        fss[fs] = "/mnt/#{name}#{mountpoint}"
        fss
      end

      if filesystems.empty?
        logger.fatal "Boot environment '#{name}' does not exist"
        return false
      end

      mounted = `zfs mount`.lines.each_with_object({}) do |line, m|
        (fs, mountpoint) = line.chomp.split
        m[fs] = mountpoint
        m
      end

      if (filesystems.to_a & mounted.to_a).to_h == filesystems
        logger.warn "The boot environment is already mounted at /mnt/#{name}"
        return true
      end

      unless (filesystems.keys & mounted.keys).empty?
        logger.fatal 'The boot environment is already mounted'
        return false
      end

      logger.info "Mounting boot environment '#{name}' at /mnt/#{name}"

      raise "Failed to make /mnt/#{name}" unless Dir.exist?("/mnt/#{name}") || cmd.run!("sudo mkdir /mnt/#{name}").success?

      filesystems.each do |fs, mountpoint|
        next if cmd.run!("sudo mount -t zfs -o zfsutil #{fs} #{mountpoint}").success?

        cmd.run("sudo umount -R /mnt/#{name}")
        cmd.run("sudo rmdir /mnt/#{name}")
        raise 'Failed to mount the boot environment. Manual cleanup may be required.'
      end

      logger.success "Mounted boot environment '#{name}' at /mnt/#{name}"
      true
    end

    def unmount(name)
      unmount_be = "#{@be_root}/#{name}"

      filesystems = `zfs list -H -o name,mountpoint -r #{unmount_be.shellescape} 2>/dev/null`.lines.each_with_object({}) do |line, fss|
        (fs, mountpoint) = line.chomp.split("\t")
        mountpoint = '' if mountpoint == '/'
        fss[fs] = "/mnt/#{name}#{mountpoint}"
        fss
      end

      if filesystems.empty?
        logger.fatal "Boot environment '#{name}' does not exist"
        return false
      end

      mounted = `zfs mount`.lines.each_with_object({}) do |line, m|
        (fs, mountpoint) = line.chomp.split
        m[fs] = mountpoint
        m
      end

      if (filesystems.to_a & mounted.to_a).empty?
        logger.warn 'The boot environment is already unmounted'
        return true
      end

      logger.info "Unmounting boot environment '#{name}'"

      if cmd.run!("sudo umount -R /mnt/#{name}").failure? || cmd.run!("sudo rmdir /mnt/#{name}").failure?
        logger.error 'Failed to unmount the boot environment. Is something using it?'
        return false
      end

      logger.success "Unmounted boot environment '#{name}'"
      true
    end
  end
end