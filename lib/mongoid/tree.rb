require 'mongoid/tree/traversal'

module Mongoid # :nodoc:
  ##
  # = Mongoid::Tree
  #
  # This module extends any Mongoid document with tree functionality.
  #
  # == Usage
  #
  # Simply include the module in any Mongoid document:
  #
  #   class Node
  #     include Mongoid::Document
  #     include Mongoid::Tree
  #   end
  #
  # === Using the tree structure
  #
  # Each document references many children. You can access them using the <tt>#children</tt> method.
  #
  #   node = Node.create
  #   node.children.create
  #   node.children.count # => 1
  #
  # Every document references one parent (unless it's a root document).
  #
  #   node = Node.create
  #   node.parent # => nil
  #   node.children.create
  #   node.children.first.parent # => node
  #
  # === Destroying
  #
  # Mongoid::Tree does not handle destroying of nodes by default. However it provides
  # several strategies that help you to deal with children of deleted documents. You can
  # simply add them as <tt>before_destroy</tt> callbacks.
  #
  # Available strategies are:
  #
  # * :nullify_children -- Sets the children's parent_id to null
  # * :move_children_to_parent -- Moves the children to the current document's parent
  # * :destroy_children -- Destroys all children by calling their #destroy method (invokes callbacks)
  # * :delete_descendants -- Deletes all descendants using a database query (doesn't invoke callbacks)
  #
  # Example:
  #
  #   class Node
  #     include Mongoid::Document
  #     include Mongoid::Tree
  #
  #     before_destroy :nullify_children
  #   end
  #
  # === Callbacks
  #
  # Mongoid::Tree offers callbacks for its rearranging process. This enables you to
  # rebuild certain fields when the document was moved in the tree. Rearranging happens
  # before the document is validated. This gives you a chance to validate your additional
  # changes done in your callbacks. See ActiveModel::Callbacks and ActiveSupport::Callbacks
  # for further details on callbacks.
  #
  # Example:
  #
  #   class Page
  #     include Mongoid::Document
  #     include Mongoid::Tree
  #
  #     after_rearrange :rebuild_path
  #
  #     field :slug
  #     field :path
  #
  #     private
  #
  #     def rebuild_path
  #       self.path = self.ancestors_and_self.collect(&:slug).join('/')
  #     end
  #   end
  #
  module Tree
    extend ActiveSupport::Concern

    include Traversal

    included do
      references_many :children, :class_name => self.name, :foreign_key => :parent_id, :inverse_of => :parent, :default_order => :position.asc
      referenced_in :parent, :class_name => self.name, :inverse_of => :children, :index => true

      field :parent_ids, :type => Array, :default => []
      index :parent_ids

      field :position, :type => Integer

      set_callback :save, :after, :rearrange_children, :if => :rearrange_children?
      set_callback :validation, :before do
        run_callbacks(:rearrange) { rearrange }
      end

      validate :position_in_tree

      define_model_callbacks :rearrange, :only => [:before, :after]

      after_rearrange :assign_default_position

      class_eval "def base_class; #{self.name}; end"
    end

    ##
    # :singleton-method: root
    # Returns the first root document

    ##
    # :singleton-method: roots
    # Returns all root documents

    ##
    # :singleton-method: leaves
    # Returns all leaves (be careful, currently involves two queries)

    ##
    # This module includes those methods documented above
    module ClassMethods # :nodoc:

      def root
        first(:conditions => { :parent_id => nil })
      end

      def roots
        where(:parent_id => nil)
      end

      def leaves
        where(:_id.nin => only(:parent_id).collect(&:parent_id))
      end

    end

    ##
    # :singleton-method: before_rearrange
    # Sets a callback that is called before the document is rearranged
    # (Generated by ActiveSupport)

    ##
    # :singleton-method: after_rearrange
    # Sets a callback that is called after the document is rearranged
    # (Generated by ActiveSupport)

    ##
    # :method: children
    # Returns a list of the document's children. It's a <tt>references_many</tt> association.
    # (Generated by Mongoid)

    ##
    # :method: parent
    # Returns the document's parent (unless it's a root document).  It's a <tt>referenced_in</tt> association.
    # (Generated by Mongoid)

    ##
    # :method: parent=
    #call-seq:
    #   parent= document
    #
    # Sets this documents parent document.
    # (Generated by Mongoid)

    ##
    # :method: parent_ids
    # Returns a list of the document's parent_ids, starting with the root node.
    # (Generated by Mongoid)

    ##
    # Is this document a root node (has no parent)?
    def root?
      parent_id.nil?
    end

    ##
    # Is this document a leaf node (has no children)?
    def leaf?
      children.empty?
    end

    ##
    # Returns the depth of this document (number of ancestors)
    def depth
      parent_ids.count
    end

    ##
    # Returns this document's root node
    def root
      base_class.find(parent_ids.first)
    end

    ##
    # Returns this document's ancestors
    def ancestors
      base_class.where(:_id.in => parent_ids)
    end

    ##
    # Returns this document's ancestors and itself
    def ancestors_and_self
      ancestors + [self]
    end

    ##
    # Is this document an ancestor of the other document?
    def ancestor_of?(other)
      other.parent_ids.include?(self.id)
    end

    ##
    # Returns this document's descendants
    def descendants
      base_class.where(:parent_ids => self.id)
    end

    ##
    # Returns this document's descendants and itself
    def descendants_and_self
      [self] + descendants
    end

    ##
    # Is this document a descendant of the other document?
    def descendant_of?(other)
      self.parent_ids.include?(other.id)
    end

    ##
    # Returns this document's siblings
    def siblings
      siblings_and_self.excludes(:id => self.id)
    end

    ##
    # Returns this document's siblings and itself
    def siblings_and_self
      base_class.where(:parent_id => self.parent_id)
    end

    ##
    # Returns all leaves of this document (be careful, currently involves two queries)
    def leaves
      base_class.where(:_id.nin => base_class.only(:parent_id).collect(&:parent_id)).and(:parent_ids => self.id)
    end

    ##
    # Forces rearranging of all children after next save
    def rearrange_children!
      @rearrange_children = true
    end

    ##
    # Will the children be rearranged after next save?
    def rearrange_children?
      !!@rearrange_children
    end

    ##
    # Nullifies all children's parent_id
    def nullify_children
      children.each { |c| c.parent = nil; c.save }
    end

    ##
    # Moves all children to this document's parent
    def move_children_to_parent
      children.each { |c| c.update_attributes(:parent_id => self.parent_id) }
    end

    ##
    # Deletes all descendants using the database (doesn't invoke callbacks)
    def delete_descendants
      base_class.delete_all(:conditions => { :parent_ids => self.id })
    end

    ##
    # Destroys all children by calling their #destroy method (does invoke callbacks)
    def destroy_children
      children.destroy_all
    end

    def lower_items
      self.siblings.where(:position.gt => self.position)
    end

    def higher_items
      self.siblings.where(:position.lt => self.position)
    end

    def last_item_in_list
      siblings_and_self.asc(:position).last
    end

    def first_item_in_list
      siblings_and_self.asc(:position).first
    end

    def at_top?
      higher_items.empty?
    end

    def at_bottom?
      lower_items.empty?
    end

    def move_to_top
      return true if at_top?
      move_above(first_item_in_list)
    end

    def move_to_bottom
      return true if at_bottom?
      move_below(last_item_in_list)
    end

    # TODO: Refactor the following two methods out into some utility methods
    # that can be reused
    def move_above(other_item)
      if parent_id != other_item.parent_id
        move_lower_items_up
        self.parent_id = other_item.parent_id
        self.save! # So that the rearrange callback happens
        self.move_above(other_item)
      else
        if position > other_item.position
          new_position = other_item.position
          other_item.lower_items.where(:position.lt => self.position).each do |item|
            item.inc(:position, 1)
          end
          other_item.inc(:position, 1)
          self.update_attributes!(:position => new_position)
        else
          new_position = other_item.position - 1
          other_item.higher_items.where(:position.gt => self.position).each do |item|
            item.inc(:position, -1)
          end
          self.update_attributes!(:position => new_position)
        end
      end
    end

    def move_below(other_item)
      if parent_id != other_item.parent_id
        move_lower_items_up
        self.parent_id = other_item.parent_id
        self.save! # So that the rearrange callback happens
        self.move_below(other_item)
      else
        if position > other_item.position
          new_position = other_item.position + 1
          other_item.lower_items.where(:position.lt => self.position).each do |item|
            item.inc(:position, 1)
          end
          self.update_attributes!(:position => new_position)
        else
          new_position = other_item.position
          other_item.higher_items.where(:position.gt => self.position).each do |item|
            item.inc(:position, -1)
          end
          other_item.inc(:position, -1)
          self.update_attributes!(:position => new_position)
        end
      end
    end

  private
    def move_lower_items_up
      lower_items.each do |item|
        item.inc(:position, -1)
      end
    end

    def assign_default_position
      self.position = nil if self.parent_ids_changed?

      if self.position.nil?
        if self.siblings.empty? || (self.siblings.collect(&:position).uniq == [nil])
          self.position = 0
        else
          self.position = self.siblings.collect(&:position).reject {|p| p.nil?}.max + 1
        end
      end
    end

    def rearrange
      if self.parent_id
        parent_ids_of_parent = base_class.find(self.parent_id).parent_ids
        if parent_ids_of_parent.nil?
          self.parent_ids = [self.parent_id]
        else
          self.parent_ids = base_class.find(self.parent_id).parent_ids + [self.parent_id]
        end
      else
        self.parent_ids = []
      end

      rearrange_children! if self.parent_ids_changed?
    end

    def rearrange_children
      @rearrange_children = false
      self.children.find(:all).each { |c| c.save }
    end

    def position_in_tree
      errors.add(:parent_id, :invalid) if self.parent_ids.include?(self.id)
    end
  end # Tree
end # Mongoid