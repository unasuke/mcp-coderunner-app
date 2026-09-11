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

  # サーバーは保持中のリースを 1 本に保証しているが、ワーカーは VPS を信用しない
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

  # bench を抱えているあいだは max_concurrency を無視して新規 lease を止める
  def test_an_exclusive_job_makes_the_worker_busy_on_its_own
    @registry.add(payload(job_id: 1, lease_id: 1, profile: "bench"))

    assert_predicate @registry, :busy?
  end

  def test_a_single_ordinary_job_leaves_room
    @registry.add(payload(job_id: 1, lease_id: 1))

    refute_predicate @registry, :busy?
  end

  # 排他ジョブは、ほかが捌けるまで走り出さない
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
