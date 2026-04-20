# frozen_string_literal: true

require 'monitor'

# Simple in-memory token-bucket rate limiter.
# Each IP gets a bucket of CAPACITY tokens; one token is consumed per request.
# Tokens refill at REFILL_RATE tokens/second up to CAPACITY.
module RateLimiter
  extend self

  CAPACITY    = 200   # max burst
  REFILL_RATE = 50    # tokens added per second
  CLEANUP_EVERY = 500 # requests between GC sweeps

  @buckets  = {}
  @monitor  = Monitor.new
  @total    = 0
  @since_gc = 0

  def allow?(ip)
    @monitor.synchronize do
      @total   += 1
      @since_gc += 1
      cleanup! if @since_gc >= CLEANUP_EVERY

      now    = Time.now.to_f
      bucket = @buckets[ip] ||= { tokens: CAPACITY.to_f, last: now }

      # Refill
      elapsed         = now - bucket[:last]
      bucket[:tokens] = [bucket[:tokens] + elapsed * REFILL_RATE, CAPACITY].min
      bucket[:last]   = now

      if bucket[:tokens] >= 1
        bucket[:tokens] -= 1
        true
      else
        false
      end
    end
  end

  def total_requests
    @monitor.synchronize { @total }
  end

  private

  def cleanup!
    cutoff = Time.now.to_f - 300 # remove buckets idle for 5 min
    @buckets.delete_if { |_, b| b[:last] < cutoff }
    @since_gc = 0
  end
end
