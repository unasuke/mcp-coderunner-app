# frozen_string_literal: true

require_relative "helper"
require "worker/job_registry"

class JobRegistryTest < Minitest::Test
  include WorkerTestHelper

  def setup
    @registry = Worker::JobRegistry.new(max_concurrency: 2)
  end

  def payload(job_id:, lease_id:, profile: "default")
    build_payload(profile:).tap do |p|
      p.instance_variable_set(:@job_id, job_id)
      p.instance_variable_set(:@lease_id, lease_id)
    end
  end

  def test_accepts_up_to_the_concurrency_limit
    assert @registry.add(payload(job_id: 1, lease_id: 1))
    assert @registry.add(payload(job_id: 2, lease_id: 2))
    assert_nil @registry.add(payload(job_id: 3, lease_id: 3))
    assert_equal 2, @registry.size
  end

  # The server guarantees a single held lease, but the worker does not take the VPS at its word
  def test_refuses_a_second_lease_for_a_running_job
    @registry.add(payload(job_id: 1, lease_id: 1))

    assert_nil @registry.add(payload(job_id: 1, lease_id: 2))
    assert_equal 1, @registry.size
  end

  def test_delete_frees_the_slot
    entry = @registry.add(payload(job_id: 1, lease_id: 1))
    @registry.delete(entry.lease_id)

    assert_predicate @registry, :empty?
    assert @registry.add(payload(job_id: 1, lease_id: 2))
  end

  # While a bench job is held, no new lease is taken regardless of max_concurrency
  def test_an_exclusive_job_makes_the_worker_busy_on_its_own
    @registry.add(payload(job_id: 1, lease_id: 1, profile: "bench"))

    assert_predicate @registry, :busy?
  end

  def test_a_single_ordinary_job_leaves_room
    @registry.add(payload(job_id: 1, lease_id: 1))

    refute_predicate @registry, :busy?
  end

  # A shutdown wants the job back in the queue; an admin wants it finished as
  # cancelled. The entry is what remembers which of the two asked
  def test_a_shutdown_cancel_is_told_apart_from_one_an_admin_asked_for
    entry = @registry.add(build_payload)
    entry.cancel!(:shutdown)

    assert_predicate entry, :cancelled?
    assert_predicate entry, :shutdown?
  end

  def test_a_cancel_already_asked_for_survives_the_shutdown
    entry = @registry.add(build_payload)
    entry.cancel!
    entry.cancel!(:shutdown)

    refute_predicate entry, :shutdown?
  end

  # An exclusive job does not start until everything else has drained
  def test_alone_is_false_while_another_job_runs
    other = @registry.add(payload(job_id: 1, lease_id: 1))
    bench = @registry.add(payload(job_id: 2, lease_id: 2, profile: "bench"))

    refute @registry.alone?(bench)

    @registry.delete(other.lease_id)

    assert @registry.alone?(bench)
  end

  def test_cancel_all_marks_every_entry
    first = @registry.add(payload(job_id: 1, lease_id: 1))
    second = @registry.add(payload(job_id: 2, lease_id: 2))

    @registry.cancel_all!

    assert_predicate first, :cancelled?
    assert_predicate second, :cancelled?
  end
end
