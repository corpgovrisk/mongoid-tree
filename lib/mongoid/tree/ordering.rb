module Mongoid
  module Tree
    ##
    # = Mongoid::Tree::Ordering
    #
    # Mongoid::Tree doesn't order the tree by default. To enable ordering of children
    # include both Mongoid::Tree and Mongoid::Tree::Ordering into your document.
    #
    # == Utility methods
    #
    # This module adds methods to get related siblings depending on their position:
    #
    #    node.lower_siblings
    #    node.higher_siblings
    #    node.first_sibling_in_list
    #    node.last_sibling_in_list
    #
    # There are several methods to move nodes around in the list:
    #
    #    node.move_up
    #    node.move_down
    #    node.move_to_top
    #    node.move_to_bottom
    #    node.move_above(other)
    #    node.move_below(other)
    #
    # Additionally there are some methods to check aspects of the document
    # in the list of children:
    #
    #    node.at_top?
    #    node.at_bottom?
    module Ordering
      extend ActiveSupport::Concern

      included do
        index({position: 1, pos_enum_sort: 1},{background: true, sparse: true})

        field :position, :type => Integer
        field :pos_enum, :type => Array, :default => []
        field :pos_enum_sort, :type => String, :default => ''
        
        default_scope asc(:pos_enum_sort)

        before_save :assign_default_position
        before_save :assign_pos_enum
        before_save :reposition_former_siblings, :if => :sibling_reposition_required?
        after_destroy :move_lower_siblings_up!
      end

      ##
      # Returns siblings below the current document.
      # Siblings with a position greater than this documents's position.
      def lower_siblings
        self.siblings.where(:position.gt => self.position)
      end

      ##
      # Returns siblings above the current document.
      # Siblings with a position lower than this documents's position.
      def higher_siblings
        self.siblings.where(:position.lt => self.position)
      end

      ##
      # Returns the lowest sibling (could be self)
      def last_sibling_in_list
        siblings_and_self.order_by([[:position, :asc]]).last
      end

      ##
      # Returns the highest sibling (could be self)
      def first_sibling_in_list
        siblings_and_self.order_by([[:position, :asc]]).first
      end

      ##
      # Is this the highest sibling?
      def at_top?
        (self.position == 0) || higher_siblings.empty?
      end

      ##
      # Is this the lowest sibling?
      def at_bottom?
        lower_siblings.empty?
      end

      ##
      # Move this node above all its siblings
      def move_to_top
        return true if at_top?
        move_above(first_sibling_in_list)
      end

      ##
      # Move this node below all its siblings
      def move_to_bottom
        return true if at_bottom?
        move_below(last_sibling_in_list)
      end

      ##
      # Move this node one position up
      def move_up
        return if at_top?
        other = siblings.where(:position => self.position - 1).first
        move_above(other)
      end

      ##
      # Move this node one position down
      def move_down
        return if at_bottom?
        other = siblings.where(:position => self.position + 1).first
        move_below(other)
      end

      ##
      # Move this node above the specified node
      #
      # This method changes the node's parent if nescessary.
      def move_above(other)
        other_id = other.is_a?(BSON::ObjectId) ? other : other.id
        return if self.id == other_id
        other = base_class.find(other_id) # Ensure other is up-to-date
        unless sibling_of?(other)
          self.parent_id = other.parent_id
          save!
        end

        if position > other.position
          new_position = other.position.to_i
          other.lower_siblings.where(:position.lt => self.position).each do |s| 
            s.position += 1
            s.save! 
          end
          other.position += 1
          other.save!
          self.position = new_position.to_i
          save!
        else
          new_position = (other.position - 1).to_i
          other.higher_siblings.where(:position.gt => self.position).each do |s| 
            s.position += -1
            s.save!
          end
          self.position = new_position.to_i
          save!
        end
      end

      ##
      # Move this node below the specified node
      #
      # This method changes the node's parent if nescessary.
      def move_below(other)
        other_id = other.is_a?(BSON::ObjectId) ? other : other.id
        return if self.id == other_id
        other = base_class.find(other_id) # Ensure other is up-to-date
        unless sibling_of?(other)
          self.parent_id = other.parent_id
          save!
        end

        if position > other.position
          new_position = (other.position + 1).to_i
          other.lower_siblings.where(:position.lt => self.position).each do |s| 
            s.position += 1
            s.save!
          end
          self.position = new_position.to_i
          save!
        else
          new_position = other.position.to_i
          other.higher_siblings.where(:position.gt => self.position).each do |s| 
            s.position += -1
            s.save!
          end
          other.position += -1
          other.save!
          self.position = new_position.to_i
          save!
        end
      end

    private
      def move_lower_siblings_up!
        lower_siblings.each do |s| 
          s.position += -1
          s.save!
        end
      end

      def reposition_former_siblings
        former_siblings = base_class.where(:parent_id => attribute_was('parent_id')).
                                     and(:position.gt => (attribute_was('position') || 0)).
                                     excludes(:id => self.id)
        former_siblings.each do |s| 
          s.position += -1
          s.save!
        end
      end

      def sibling_reposition_required?
        self.changes.include?('parent_id') && persisted?
      end

      def assign_default_position
        return unless (self.position.nil? || self.parent_id_changed?)

        if self.siblings.empty? || self.siblings.collect(&:position).compact.empty?
          self.position = 0
        else
          # Max can return "start" due to a mongoid bug.
          max = self.siblings.max(:position)
          # "start" only occurs when the query set for the map reduce result are 0 for all.
          # This should also deprecate gracefully if it gets fixed.
          cleaned_max = (max.is_a?(Numeric) ? max : 0)
          self.position = (cleaned_max + 1).to_i
        end
      end
      
      def assign_pos_enum
        if self.parent_id
          self.pos_enum = self.parent.pos_enum + [self.position]
        else
          self.pos_enum = [self.position]
        end
        self.pos_enum_sort = self.pos_enum.collect { |i| "%05d" % i.to_i }.join(',')
        rearrange_children! if self.changes.include?('pos_enum')
      end
    end
  end
end
