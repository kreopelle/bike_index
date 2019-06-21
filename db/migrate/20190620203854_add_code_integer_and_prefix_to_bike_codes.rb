class AddCodeIntegerAndPrefixToBikeCodes < ActiveRecord::Migration
  def change
    add_column :bike_codes, :code_integer, :integer
    add_column :bike_codes, :code_prefix, :string
    add_column :bike_code_batches, :code_number_length, :integer
  end
end
