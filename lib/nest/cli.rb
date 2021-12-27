# frozen_string_literal: true

require 'thor'

module Nest
  # Entrypoint to the Nest CLI
  # @author James Lee
  class CLI < Thor
    desc 'hello NAME', 'say hello to NAME'
    def hello(name)
      puts "Hello #{name}"
    end
  end
end
