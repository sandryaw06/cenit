module Setup
  class DataType
    include Mongoid::Document
    include Mongoid::Timestamps
    include AccountScoped

    def self.to_include_in_models
      @to_include_in_models ||= [Mongoid::Document, Mongoid::Timestamps, AfterSave, AccountScoped]
    end

    def self.to_include_in_model_classes
      @to_include_in_model_classes ||= [AffectRelation]
    end

    belongs_to :uri, class_name: Setup::Schema.to_s

    field :name, type: String
    field :schema, type: String
    field :sample_data, type: String

    validates_length_of :name, :maximum => 50
    #validates_format_of :name, :with => /^([A-Z][a-z]*)(::([A-Z][a-z]*)+)*$/, :multiline => true
    validates_uniqueness_of :name
    validates_presence_of :name, :schema

    before_save :validate_model
    after_save :verify_schema_ok
    before_destroy :destroy_model
    after_initialize :verify_schema_ok

    field :is_object, type: Boolean
    field :schema_ok, type: Boolean
    field :previous_schema, type: String

    def sample_object
      '{"' + name.underscore + '": ' + sample_data + '}'
    end

    def destroy_model
      return deconstantize(self.name)
    end

    def load_model(reload=true)
      model = nil
      begin
        if reload || schema_has_changed?
          destroy_model
          model = parse_str_schema(self.name, self.schema)
        else
          puts "No changes detected on '#{self.name}' schema!"
        end
      rescue Exception => ex
        #raise ex
        puts "ERROR: #{errors.add(:schema, ex.message).to_s}"
        destroy_model
        begin
          if previous_schema
            puts "Reloading previous schema for '#{self.name}'..."
            parse_str_schema(self.name, previous_schema)
            puts "Previous schema for '#{self.name}' reloaded!"
          else
            puts "ERROR: schema '#{self.name}' not loaded!"
          end
        rescue Exception => ex
          puts "ERROR: schema '#{self.name}' with permanent error (#{ex.message})"
        end
        destroy_model
        return false
      end
      set_schema_ok
      self[:previous_schema] = nil
      return model
    end

    rails_admin do
      list do
        fields :name, :schema, :sample_data
      end
      show do
        field :_id
        field :created_at
        field :updated_at
        field :name
        field :schema
        field :sample_data
      end
      edit do

        group :model_definition do
          label 'Model definition'
          active true
        end

        field :uri do
          group :model_definition
          read_only true
          help ''
        end

        field :name do
          group :model_definition
          read_only true
          help ''
        end

        field :schema do
          group :model_definition
          read_only true
          help ''
        end

        group :sample_data do
          label 'Sample data'
          active do
            !bindings[:object].errors.get(:sample_data).blank?
          end
          visible do
            bindings[:object].is_object
          end
        end

        field :sample_data do
          group :sample_data
        end
      end
      list do
        fields :uri, :name, :schema, :sample_data
      end

      show do
        fields :uri, :name, :schema, :sample_data
      end
    end

    private

    def validate_model
      begin
        puts "Validating schema '#{self.name}'"
        json = validate_schema
        puts "Schema '#{self.name}' validation successful!"
      rescue Exception => ex
        puts "ERROR: #{errors.add(:schema, ex.message).to_s}"
        return false
      end
      begin
        if self.sample_data && !self.sample_data.blank?
          puts 'Validating sample data...'
          Cenit::JSONSchemaValidator.validate!(self.schema, self.sample_data)
          puts 'Sample data validation successfully!'
        end
      rescue Exception => ex
        puts "ERROR: #{errors.add(:sample_data, "fails schema validation: #{ex.message} (#{ex.class})").to_s}"
        return false
      end
      return true
    end

    def schema_has_changed?
      self.previous_schema ? JSON.parse(self.previous_schema) != JSON.parse(self.schema) : true
    end

    def previous_schema_ok?
      self.schema_ok
    end

    def set_schema_ok
      self.schema_ok = true
      verify_schema_ok
    end

    def verify_schema_ok
      self.previous_schema = self.schema if previous_schema_ok?
    end

    def deconstantize(constant_name, report={destroyed: Set.new, affected: Set.new})
      if constant = constant_name.constantize rescue nil
        if constant.is_a?(Class)
          deconstantize_class(constant, report)
        else
          puts "Deconstantizing constant #{constant_name}"
          if affected_models = constant[:affected]
            affected_models.each { |model| deconstantize_class(model, report, :affected) }
          end
          tokens = constant_name.split('::')
          constant_name = tokens.pop
          parent = tokens.join('::').constantize rescue Object
          parent.send(:remove_const, constant_name)
        end
      end
      return report
    end

    def deconstantize_class(klass, report={:destroyed => Set.new, :affected => Set.new}, affected=nil)
      if !affected && report[:affected].include?(klass)
        report[:affected].delete(klass)
        report[:destroyed] << klass
      end
      return report if report[:destroyed].include?(klass) || report[:affected].include?(klass)
      return report unless @@parsed_schemas.include?(klass.to_s) || @@parsing_schemas.include?(klass)
      parent = klass.parent
      affected = nil if report[:destroyed].include?(parent)
      puts "#{affected ? 'Affecting' : 'Deconstantizing'} class #{klass.to_s}" #" is #{affected ? 'affected' : 'in tree'} -> #{report.to_s}"
      if (affected)
        report[:affected] << klass
      else
        report[:destroyed] << klass
      end

      unless affected
        @@parsed_schemas.delete(klass.to_s)
        @@parsing_schemas.delete(klass)
        [@@has_many_to_bind,
         @@has_one_to_bind,
         @@embeds_many_to_bind,
         @@embeds_one_to_bind].each { |to_bind| delete_pending_bindings(to_bind, klass) }
      end

      klass.constants(false).each do |const_name|
        if klass.const_defined?(const_name, false)
          const = klass.const_get(const_name, false)
          deconstantize_class(const, report, affected) if const.is_a?(Class)
        end
      end
      [:embeds_one, :embeds_many, :embedded_in].each do |rk|
        begin
          klass.reflect_on_all_associations(rk).each do |r|
            deconstantize_class(r.klass, report, :affected)
          end
        rescue
        end
      end
      # referenced relations only affects if a referenced relation reflects back
      {[:belongs_to] => [:has_one, :has_many],
       [:has_one, :has_many] => [:belongs_to],
       [:has_and_belongs_to_many] => [:has_and_belongs_to_many]}.each do |rks, rkbacks|
        rks.each do |rk|
          klass.reflect_on_all_associations(rk).each do |r|
            rkbacks.each do |rkback|
              deconstantize_class(r.klass, report, :affected) if r.klass.reflect_on_all_associations(rkback).detect { |r| r.klass.eql?(klass) }
            end
          end
        end
      end
      klass.affected_models.each { |m| deconstantize_class(m, report, :affected) }
      parent.send(:remove_const, klass.to_s.split('::').last) unless affected
      deconstantize_class(parent, report, affected) if affected
      return report
    end

    def delete_pending_bindings(to_bind, model)
      to_bind.delete_if { |property_type, _| property_type.eql?(model.to_s) }
      #to_bind.each { |property_type, a| a.delete_if { |x| x[0].eql?(model.to_s) } }
    end

    def validate_schema
      check_type_name(self.name)
      JSON::Validator.validate!(File.read(File.dirname(__FILE__) + '/schema.json'), self.schema)
      json = JSON.parse(self.schema, :object_class => MultKeyHash)
      if json['type'] == 'object'
        check_schema(json, self.name, defined_types=[], embedded_refs=[])
        embedded_refs = embedded_refs.uniq.collect { |ref| self.name + ref }
        puts "Defined types #{defined_types.to_s}"
        puts "Embedded references #{embedded_refs.to_s}"
        embedded_refs.each { |ref| raise Exception.new(" embedded reference #/#{ref.underscore} is not defined") unless defined_types.include?(ref) }
      end
      return json
    end

    def check_schema(json, name, defined_types, embedded_refs)
      if ref=json['$ref']
        embedded_refs << check_embedded_ref(ref) if ref.start_with?('#')
      elsif json['type'].nil? || json['type'].eql?('object')
        raise Exception.new("defines multiple properties with name '#{json.mult_key_def.first.to_s}'") unless json.mult_key_def.blank?
        defined_types << name
        check_definitions(json, name, defined_types, embedded_refs)
        if properties=json['properties']
          raise Exception.new('properties specification is invalid') unless properties.is_a?(MultKeyHash)
          raise Exception.new("defines multiple properties with name '#{properties.mult_key_def.first.to_s}'") unless properties.mult_key_def.blank?
          properties.each do |property_name, property_spec|
            check_property_name(property_name)
            raise Exception.new("specification of property '#{property_name}' is not valid") unless property_spec.is_a?(Hash)
            if defined_types.include?(camelized_property_name = "#{name}::#{property_name.camelize}") && !(property_spec['$ref'] || 'object'.eql?(property_spec['type']))
              raise Exception.new("'#{name.underscore}' already defines #{property_name} (use #/[definitions|properties]/#{property_name} instead)")
            end
            check_schema(property_spec, camelized_property_name, defined_types, embedded_refs)
          end
        end
        check_requires(json)
      end
    end

    def check_embedded_ref(ref, root_name='')
      raise Exception.new("invalid format for embedded reference #{ref}") unless ref =~ /\A#(\/[a-z]+(_|([0-9]|[a-z])+)*)*\Z/
      raise Exception.new("embedding itself (referencing '#')") if ref.eql?('#')
      tokens = ref.split('/')
      tokens.shift
      type = root_name
      while !tokens.empty?
        token = tokens.shift
        raise Exception.new("use invalid embedded reference path '#{ref}'") unless %w{properties definitions}.include?(token) && !tokens.empty?
        token = tokens.shift
        type = "#{type}::#{token.camelize}"
      end
      return type
    end

    def check_requires(json)
      properties=json['properties']
      if required = json['required']
        if required.is_a?(Array)
          required.each do |property|
            if property.is_a?(String)
              raise Exception.new("requires undefined property '#{property.to_s}'") unless properties && properties[property]
            else
              raise Exception.new("required item \'#{property.to_s}\' is not a property name (string)")
            end
          end
        else
          raise Exception.new('required clause is not an array')
        end
      end
    end

    def check_definitions(json, parent, defined_types, embedded_refs)
      raise Exception.new("multiples definitions with name '#{json.mult_key_def.first.to_s}'") unless json.mult_key_def.blank?
      if defs=json['definitions']
        raise Exception.new('definitions format is invalid') unless defs.is_a?(MultKeyHash)
        raise Exception.new("multiples definitions with name '#{defs.mult_key_def.first.to_s}'") unless defs.mult_key_def.blank?
        defs.each do |def_name, def_spec|
          raise Exception.new("type definition '#{def_name}' is not an object type") unless def_spec.is_a?(Hash) && (def_spec['type'].nil? || def_spec['type'].eql?('object'))
          check_definition_name(def_name)
          raise Exception.new("'#{parent.underscore}/#{def_name}' definition is declared as a reference (use the reference instead)") if def_spec['$ref']
          raise Exception.new("'#{parent.underscore}' already defines #{def_name}") if defined_types.include?(camelized_def_name = "#{parent}::#{def_name.camelize}")
          check_schema(def_spec, camelized_def_name, defined_types, embedded_refs)
        end
      end
    end

    def check_type_name(type_name)
      type_name = type_name.underscore.camelize
      # unless @@parsed_schemas.include?(model = type_name.constantize) || @@parsing_schemas.include?(model)
      #   raise Exception.new ("using type name '#{type_name}'is invalid")
      # end
    end

    def check_definition_name(def_name)
      #raise Exception.new("definition name '#{def_name}' is not valid") unless def_name =~ /\A([A-Z]|[a-z])+(_|([0-9]|[a-z]|[A-Z])+)*\Z/
      raise Exception.new("definition name '#{def_name}' is not valid") unless def_name =~ /\A[a-z]+(_|([0-9]|[a-z])+)*\Z/
    end

    def check_property_name(property_name)
      #raise Exception.new("property name '#{property_name}' is invalid") unless property_name =~ /\A[a-z]+(_|([0-9]|[a-z])+)*\Z/
    end

    RJSON_MAP={'string' => 'String',
               'integer' => 'Integer',
               'number' => 'Float',
               'string' => 'String',
               'array' => 'Array',
               'boolean' => 'Boolean',
               'date' => 'Date',
               'time' => 'Time',
               'date_time' => 'DateTime'}

    MONGO_TYPES= %w{Array BigDecimal Boolean Date DateTime Float Hash Integer Range String Symbol Time}

    @@pending_bindings
    @@has_many_to_bind = Hash.new { |h, k| h[k]=[] }
    @@has_one_to_bind = Hash.new { |h, k| h[k]=[] }
    @@embeds_many_to_bind = Hash.new { |h, k| h[k]=[] }
    @@embeds_one_to_bind = Hash.new { |h, k| h[k]=[] }
    @@parsing_schemas = Set.new
    @@parsed_schemas = Set.new

    def reflect_constant(name, value=nil, parent=nil)

      model_name = (parent ? "#{parent.to_s}::" : '') + name

      do_not_create = value == :do_not_create

      tokens = name.split('::')

      constant_name = tokens.pop

      unless parent || tokens.empty?
        begin
          raise "uses illegal constant #{tokens[0]}" unless (@@parsing_schemas.include?(parent = tokens[0].constantize) || @@parsed_schemas.include?(parent.to_s)) && parent.is_a?(Module)
        rescue
          return nil if do_not_create
          parent = Class.new
          Object.const_set(tokens[0], parent)
        end
        tokens.shift
      end

      tokens.each do |token|
        if parent.const_defined?(token, false)
          parent = parent.const_get(token)
          raise "uses illegal constant #{parent.to_s}" unless (@@parsing_schemas.include?(parent) || @@parsed_schemas.include?(parent.to_s)) && parent.is_a?(Module)
        else
          return nil if do_not_create
          new_m = Class.new
          parent.const_set(token, new_m)
          parent = new_m
        end
      end
      parent ||= Object
      sc = MONGO_TYPES.include?(constant_name) ? Object : parent.const_get('Base') rescue Object
      if parent.const_defined?(constant_name, false)
        c = parent.const_get(constant_name)
        raise "uses illegal constant #{c.to_s}" unless @@parsed_schemas.include?(model_name) || (c.is_a?(Class) && @@parsing_schemas.include?(c))
      else
        return nil if do_not_create
        c = Class.new(sc) unless c = value
        parent.const_set(constant_name, c)
      end
      unless do_not_create
        if c.is_a?(Class)
          puts "Created class #{c.to_s} < #{sc.to_s}"
          DataType.to_include_in_models.each do |module_to_include|
            unless c.include?(module_to_include)
              puts "#{c.to_s} including #{module_to_include.to_s}."
              c.include(module_to_include)
            end
          end
          DataType.to_include_in_model_classes.each do |module_to_include|
            unless c.class.include?(module_to_include)
              puts "#{c.to_s} class including #{module_to_include.to_s}."
              c.class.include(module_to_include)
            end
          end
        else
          @@parsed_schemas << name
          puts "Created constant #{constant_name}"
        end
      end
      return c
    end

    def parse_str_schema(model_name, str_schema)
      parse_schema(model_name, JSON.parse(str_schema))
    end

    def parse_schema(model_name, schema, root = nil, parent=nil, embedded=nil)

      #model_name = pick_model_name(parent) unless model_name || (model_name = schema['title'])

      klass = reflect_constant(model_name, schema['type'] == 'object' ? nil : schema, parent)

      nested = []
      enums = {}
      validations = []

      unless klass.is_a?(Class)
        check_pending_binds(model_name, klass, root)
        self.is_object = false
        return klass
      end

      self.is_object = true

      model_name = klass.to_s

      begin

        @@parsing_schemas << klass

        if @@parsed_schemas.include?(klass.to_s)
          puts "Model #{klass.to_s} already parsed"
          return klass
        end

        reflect(klass, "embedded_in :#{relation_name(parent)}, class_name: \'#{parent.to_s}\'") if parent && embedded

        root ||= klass;

        puts "Parsing #{model_name}"

        if definitions = schema['definitions']
          definitions.each do |def_name, def_desc|
            def_name = def_name.camelize
            puts 'Defining ' + def_name
            parse_schema(def_name, def_desc, root ? root : klass, klass)
          end
        end

        if properties=schema['properties']
          raise Exception.new('properties definition is invalid') unless properties.is_a?(Hash)
          schema['properties'].each do |property_name, property_desc|
            raise Exception.new("property '#{property_name}' definition is invalid") unless property_desc.is_a?(Hash)
            check_property_name(property_name)
            v = nil
            still_trying = true
            referenced = property_desc['referenced']

            while still_trying && ref = property_desc['$ref'] # property type is a reference
              still_trying = false
              if ref.start_with?('#') # an embedded reference
                raise Exception.new("referencing embedded reference #{ref}") if referenced
                property_type = check_embedded_ref(ref, root.to_s)
                if @@parsed_schemas.detect { |m| m.eql?(property_type) }
                  if type_model = reflect_constant(property_type, :do_not_create)
                    v = "embeds_one :#{property_name}, class_name: \'#{type_model.to_s}\'"
                    reflect(type_model, "embedded_in :#{relation_name(model_name)}, class_name: \'#{model_name}\'")
                    nested << property_name
                  else
                    raise Exception.new("refers to an invalid JSON reference '#{ref}'")
                  end
                else
                  puts "#{klass.to_s}  Waiting for parsing #{property_type} to bind property #{property_name}"
                  @@embeds_one_to_bind[model_name] << [property_type, property_name]
                end
              else # external reference
                if MONGO_TYPES.include?(ref)
                  v = "field :#{property_name}, type: #{ref}"
                else
                  ref = check_type_name(ref)
                  if type_model = reflect_constant(ref, :do_not_create)
                    if type_model.is_a?(Hash)
                      property_desc.delete('$ref')
                      property_desc = property_desc.merge(type_model)
                      bind_affect_to_relation(type_model, klass)
                      still_trying = true
                    else
                      if referenced
                        v = "belongs_to :#{property_name}, class_name: \'#{ref}\'"
                        type_model.affects_to(klass)
                      else
                        v = "embeds_one :#{property_name}, class_name: \'#{type_model.to_s}\'"
                        reflect(type_model, "embedded_in :#{relation_name(model_name)}, class_name: \'#{model_name}\'")
                        nested << property_name
                      end
                    end
                  else
                    puts "#{klass.to_s}  Waiting for parsing #{ref} to bind property #{property_name}"
                    (referenced ? @@has_one_to_bind : @@embeds_one_to_bind)[model_name] << [ref, property_name]
                  end
                end
              end
            end

            v = process_non_ref(property_name, property_desc, klass, root, nested, enums, validations) if still_trying

            reflect(klass, v) if v
          end
        end

        if r = schema['required']
          r.each do |p|
            if klass.fields.keys.include?(p)
              reflect(klass, "validates_presence_of :#{p}")
            else
              [@@has_many_to_bind,
               @@has_one_to_bind,
               @@embeds_many_to_bind,
               @@embeds_one_to_bind].each do |to_bind|
                to_bind.each do |property_type, pending_bindings|
                  pending_bindings.each do |binding_info|
                    binding_info << true if binding_info[1] == p
                  end if property_type == klass.to_s
                end
              end
            end
          end
        end

        validations.each { |v| reflect(klass, v) }

        enums.each do |property_name, enum|
          reflect(klass, %{
          def #{property_name}_enum
            #{enum.to_s}
          end
          })
        end

        @@parsed_schemas << klass.to_s

        check_pending_binds(model_name, klass, root)

        nested.each { |n| reflect(klass, "accepts_nested_attributes_for :#{n}") }

        @@parsing_schemas.delete(klass)

        puts "Parsing #{model_name} done!"

        return klass

      rescue Exception => ex
        @@parsing_schemas.delete(klass)
        @@parsed_schemas << klass.to_s
        raise ex
      end
    end

    def bind_affect_to_relation(json_schema, model)
      puts "#{json_schema['title']} affects #{model.to_s}"
      json_schema[:affected] ||= []
      json_schema[:affected] << model
    end

    def process_non_ref(property_name, property_desc, klass, root, nested=[], enums={}, validations=[])
      model_name = klass.to_s
      still_trying = true
      while still_trying
        still_trying = false
        unless property_type = property_desc['type']
          property_type = 'object'
        end
        property_type = RJSON_MAP[property_type] if RJSON_MAP[property_type]
        if property_type.eql?('Array') && (items_desc = property_desc['items'])
          r = nil
          if referenced = ((ref = items_desc['$ref']) && (!ref.start_with?('#') && items_desc['referenced']))
            ref = check_type_name(ref)
            if (type_model = reflect_constant(property_type = ref, :do_not_create)) &&
                @@parsed_schemas.include?(type_model.to_s)
              puts "#{klass.to_s}  Binding property #{property_name}"
              if (a = @@has_many_to_bind[property_type]) && i = a.find_index { |x| x[0].eql?(model_name) }
                a = a.delete_at(i)
                reflect(klass, "has_and_belongs_to_many :#{property_name}, class_name: \'#{property_type}\'")
                reflect(type_model, "has_and_belongs_to_many :#{a[1]}, class_name: \'#{model_name}\'")
              else
                if type_model.reflect_on_all_associations(:belongs_to).detect { |r| r.klass.eql?(klass) }
                  r = 'has_many'
                else
                  r = 'has_and_belongs_to_many'
                  type_model.affects_to(klass)
                end
              end
            else
              puts "#{klass.to_s}  Waiting for parsing #{property_type} to bind property #{property_name}"
              @@has_many_to_bind[model_name] << [property_type, property_name]
            end
          else
            r = 'embeds_many'
            if ref
              raise Exception.new("referencing embedded reference #{ref}") if items_desc['referenced']
              property_type = ref.start_with?('#') ? check_embedded_ref(ref, root.to_s).singularize : check_type_name(ref)
              if @@parsed_schemas.detect { |m| m.eql?(property_type) }
                if type_model = reflect_constant(property_type, :do_not_create)
                  reflect(type_model, "embedded_in :#{relation_name(model_name)}, class_name: \'#{type_model.to_s}\'")
                else
                  raise Exception.new("refers to an invalid JSON reference '#{ref}'")
                end
              else
                r = nil
                puts "#{klass.to_s}  Waiting for parsing #{property_type} to bind property #{property_name}"
                @@embeds_many_to_bind[model_name] << [property_type, property_name]
              end
            else
              property_type = (type_model = parse_schema(property_name.camelize.singularize, property_desc['items'], root, klass, :embedded)).to_s
            end
            nested << property_name if r
          end
          if r
            v = "#{r} :#{property_name}, class_name: \'#{property_type.to_s}\'"
            # embedded_in relation reflected before if ref or it is reflected when parsing with :embedded option
            #reflect(type_model, "#{referenced ? 'belongs_to' : 'embedded_in'} :#{relation_name(model_name)}, class_name: \'#{model_name}\'")
            #reflect(type_model, "belongs_to :#{relation_name(model_name)}, class_name: '#{model_name}'") if referenced
          end
        else
          v =nil
          if property_type.eql?('object')
            if property_desc['properties']
              property_type = (type_model = parse_schema(property_name.camelize, property_desc, root, klass, :embedded)).to_s
              v = "embeds_one :#{property_name}, class_name: \'#{type_model.to_s}\'"
              #reflect(type_model, "embedded_in :#{relation_name(model_name)}, class_name: \'#{model_name}\'")
              nested << property_name
            else
              property_type = 'Hash'
            end
          end
          unless v
            v = "field :#{property_name}, type: #{property_type}"
            if property_desc['default']
              v += ", default: \'#{property_desc['default']}\'"
            end
            if property_type.eql?('String')
              if property_desc['minLength'] || property_desc['maxLength']
                validations << "validates_length_of :#{property_name}#{property_desc['minLength'] ? ', :minimum => ' + property_desc['minLength'].to_s : ''}#{property_desc['maxLength'] ? ', :maximum => ' + property_desc['maxLength'].to_s : ''}"
              end
              if property_desc['pattern']
                validations << "validates_format_of :#{property_name}, :with => /#{property_desc['pattern']}/i"
              end
            end
            if property_type.eql?('Float') || property_type.eql?('Integer')
              constraints = []
              if property_desc['minimum']
                constraints << (property_desc['exclusiveMinimum'] ? 'greater_than: ' : 'greater_than_or_equal_to: ') + property_desc['minimum'].to_s
              end
              if property_desc['maximum']
                constraints << (property_desc['exclusiveMaximum'] ? 'less_than: ' : 'less_than_or_equal_to: ') + property_desc['maximum'].to_s
              end
              if constraints.length > 0
                validations << "validates_numericality_of :#{property_name}, {#{constraints[0] + (constraints[1] ? ', ' + constraints[1] : '')}}"
              end
            end
            if property_desc['unique']
              validations << "validates_uniqueness_of :#{property_name}"
            end
            if enum = property_desc['enum']
              enums[property_name] = enum
            end
          end
        end
      end
      return v
    end

    def check_pending_binds(model_name, klass, root)

      @@has_many_to_bind.each do |property_type, a|
        if i = a.find_index { |x| x[0].eql?(model_name) }
          a = a.delete_at(i)
          puts "#{(type_model = reflect_constant(property_type, :do_not_create)).to_s}  Binding property #{a[1]}"
          if klass.is_a?(Class)
            if klass.reflect_on_all_associations(:belongs_to).detect { |r| r.klass.eql?(type_model) }
              reflect(type_model, "has_many :#{a[1]}, class_name: \'#{model_name}\'")
            else
              reflect(type_model, "has_and_belongs_to_many :#{a[1]}, class_name: \'#{model_name}\'")
              klass.affects_to(type_model)
            end
          else #must be a json schema
            reflect(type_model, process_non_ref(a[1], klass, type_model, root))
            bind_affect_to_relation(klass, type_model)
          end
          if a[2]
            reflect(type_model, "validates_presence_of :#{a[1]}")
          end
        end
      end

      @@has_one_to_bind.each do |property_type, pending_binds|
        if i = pending_binds.find_index { |x| x[0].eql?(model_name) }
          a = pending_binds.delete_at(i)
          puts (type_model = reflect_constant(property_type, :do_not_create)).to_s + '  Binding property ' + a[1]
          if klass.is_a?(Class)
            reflect(type_model, "belongs_to :#{a[1]}, class_name: \'#{model_name}\'")
            klass.affects_to(type_model)
          else #must be a json schema
            reflect(type_model, process_non_ref(a[1], klass, type_model, root))
            bind_affect_to_relation(klass, type_model)
          end
          if a[2]
            reflect(type_model, "validates_presence_of :#{a[1]}")
          end
        end
      end

      {:embeds_many => @@embeds_many_to_bind, :embeds_one => @@embeds_one_to_bind}.each do |r, to_bind|
        to_bind.each do |property_type, pending_binds|
          if i = pending_binds.find_index { |x| x[0].eql?(model_name) }
            a = pending_binds.delete_at(i)
            puts (type_model = reflect_constant(property_type, :do_not_create)).to_s + '  Binding property ' + a[1]
            if klass.is_a?(Class)
              reflect(type_model, "#{r.to_s} :#{a[1]}, class_name: \'#{model_name}\'")
              reflect(type_model, "accepts_nested_attributes_for :#{a[1]}")
              reflect(klass, "embedded_in :#{property_type.underscore.split('/').join('_')}, class_name: '#{property_type}'")
            else #must be a json schema
              reflect(type_model, process_non_ref(a[1], klass, type_model, root))
              bind_affect_to_relation(klass, type_model)
            end
            if a[2]
              reflect(type_model, "validates_presence_of :#{a[1]}")
            end
          end
        end
      end
    end

    def relation_name(model)
      model.to_s.underscore.split('/').join('_')
    end

    # def pick_model_name(parent_module)
    #   parent_module ||= Object
    #   i = 1
    #   model_name = 'Model'
    #   while parent_module.const_defined?(model_name)
    #     model_name = 'Model' + (i=i+1).to_s
    #   end
    #   return model_name
    # end

    def reflect(c, code)
      puts "#{c.to_s}  #{code ? code : 'WARNING REFLECTING NIL CODE'}"
      c.class_eval(code) if code
    end

    def find_embedded_ref(root, ref)
      begin
        ref.split('/').each do |name|
          unless name.length == 0 || name.eql?('#') || name.eql?('definitions')
            root = root.const_get(name.camelize)
          end
        end
        return root
      rescue
        return nil
      end
    end

    class MultKeyHash < Hash

      attr_reader :mult_key_def

      def initialize
        @mult_key_def = []
      end

      def store(key, value)
        @mult_key_def << key if (self[key] && !@mult_key_def.include?(key))
        super
      end

      def []=(key, value)
        @mult_key_def << key if (self[key] && !@mult_key_def.include?(key))
        super
      end
    end

    module AffectRelation

      def affected_models
        @affected_models ||= Set.new
      end

      def affects_to(model)
        puts "#{self.to_s} affects #{model.to_s}"
        (@affected_models ||= Set.new)<< model
      end
    end
  end
end
