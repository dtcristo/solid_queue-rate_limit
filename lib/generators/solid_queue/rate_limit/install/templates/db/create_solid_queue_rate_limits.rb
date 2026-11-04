class CreateSolidQueueRateLimits < ActiveRecord::Migration[7.1]
  def change
    create_table :solid_queue_rate_limits do |t|
      t.string :key, null: false
      t.datetime :tat, null: false
      t.datetime :deferred_until
      t.timestamps

      t.index :key, unique: true
    end
  end
end
