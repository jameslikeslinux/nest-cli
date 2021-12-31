# frozen_string_literal: true

module Nest
  class Installer
    # Platform installer overrides
    class BeagleBoneBlack < Installer
      def format(passphrase = nil)
        super(passphrase, '1536M')
      end
    end
  end
end