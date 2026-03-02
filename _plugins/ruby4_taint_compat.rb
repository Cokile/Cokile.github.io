# Ruby 4 compatibility for Liquid 4 used by Jekyll 4.x.
# Ruby 3.2+ removed taint APIs (`tainted?`, `taint`, `untaint`).
class Object
  unless method_defined?(:tainted?)
    def tainted?
      false
    end
  end

  unless method_defined?(:taint)
    def taint
      self
    end
  end

  unless method_defined?(:untaint)
    def untaint
      self
    end
  end
end
