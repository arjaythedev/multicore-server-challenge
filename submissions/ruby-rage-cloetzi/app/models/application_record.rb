class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # A constant SQL fragment, with any values as `?` binds. Active Record won't prepare a statement that
  # contains a plain SQL string, in case values were interpolated into it; these fragments never are, so
  # their statements stay prepared and Postgres skips the parse and plan on every request.
  def self.bound_sql(fragment, *binds) = Arel::Nodes::BoundSqlLiteral.new(fragment, binds, {})

  # where(column: subquery) for a subquery that yields at most one value (an id looked up by a unique key),
  # written as `column = (subquery)`. Plain `where` writes `IN (subquery)`, which Postgres plans as a join, so
  # it can't walk an index in order and stop after a page: it fetches every match and sorts them first.
  def self.where_scalar(**conditions)
    where(conditions.map { |column, subquery| arel_table[column].eq(subquery.arel) }.reduce(:and))
  end

  # The API caps every list total at 1,000: count the relation, but stop counting there.
  def self.capped_count(relation, cap: 1000)
    capped = relation.unscope(:select, :order).select(bound_sql("1")).limit(cap)
    relation.model.unscoped.from(capped, :capped).pick(bound_sql("count(*)"))
  end
end
