if this.Continuum
  Continuum = this.Continuum
else
  Continuum = {}
  this.Continuum = Continuum
Collections = {}
Continuum.Collections = Collections
Continuum.register_collection = (key, value) ->
  Collections[key] = value
  value.bokeh_key = key

# HasReference
# Backbone model, which can output a reference (combination of type, and id)
# also auto creates an id on init, if one isn't passed in.

class HasProperties extends Backbone.Model
  initialize : (attrs, options) ->
    super(attrs, options)
    #property, key is prop name, value is list of dependencies
    #depdencies, key is backbone attribute, multidict value is list of
    #properties that depend on it
    @properties = {}
    @dependencies = new buckets.MultiDictionary
    @property_cache = {}

  register_property : (prop_name, dependencies, property, use_cache) ->
    # remove a property before registering it if we arleady have it
    # store the property function, it's dependencies, whetehr
    # we want to cache it
    # and a callback, which invalidates the cache
    # hook up dependencies data structure,
    # if we're using the cache, register attribute changes on
    # property to invalidate cache for it
    if _.has(@properties, prop_name)
      @remove_property(prop_name)
    prop_spec=
      'property' : property,
      'dependencies' : dependencies,
      'use_cache' : use_cache
      'invalidate_cache_callback' : =>
        @clear_cache(prop_name)
    @properties[prop_name] = prop_spec
    for dep in dependencies
      @dependencies.set(dep, prop_name)
      if prop_spec.use_cache
        @on("change:" + dep, @properties[prop_name].invalidate_cache_callback)

  remove_property : (prop_name) ->
    # remove property from dependency data structure
    # unbind change callbacks if we're using the cache
    # delete the property object from the @properties object
    # clear the cache if we were using it

    prop_spec = @properties[prop_name]
    dependencies = prop_spec.dependencies
    for dep in dependencies
      @dependencies.remove(dep, prop_name)
      if prop_spec.use_cache
        @off("change:" + dep, prop_spec['invalidate_cache_callback'])
    delete @properties[prop_name]
    if prop_spec.use_cache
      @clear_cache(prop_name)

  has_cache : (prop_name) ->
    return _.has(@property_cache, prop_name)

  add_cache : (prop_name, val) ->
    @property_cache[prop_name] = val

  clear_cache : (prop_name, val) ->
    delete @property_cache[prop_name]

  get_cache : (prop_name) ->
    return @property_cache[prop_name]

  get : (prop_name) ->
    if _.has(@properties, prop_name)
      prop_spec = @properties[prop_name]
      if prop_spec.use_cache and @has_cache(prop_name)
        return @property_cache[prop_name]
      else
        dependencies = prop_spec.dependencies
        property = prop_spec.property
        dependencies = (@get(x) for x in dependencies)
        computed = property.apply(this, dependencies)
        if @properties[prop_name].use_cache
          @add_cache(prop_name, computed)
        return computed
    else
      return super(prop_name)

class HasReference extends HasProperties
  type : null
  initialize : (attrs, options) ->
    super(attrs, options)
    if not _.has(attrs, 'id')
      this.id = _.uniqueId(this.type)
      this.attributes['id'] = this.id
  ref : ->
    'type' : this.type
    'id' : this.id
  resolve_ref : (ref) ->
    Collections[ref['type']].get(ref['id'])
  get_ref : (ref_name) ->
    ref = @get(ref_name)
    if ref
      return @resolve_ref(ref)

class ContinuumView extends Backbone.View
  initialize : (options) ->
    if not _.has(options, 'id')
      this.id = _.uniqueId('ContinuumView')

  remove : ->
    @model.off(null, null, this)
    super()

  tag_selector : (tag, id) ->
    return "#" + @tag_id(tag, id)

  tag_id : (tag, id) ->
    if not id
      id = this.id
    tag + "-" + id
  tag_el : (tag, id) ->
    @$el.find("#" + this.tag_id(tag, id))
  tag_d3 : (tag, id) ->
    val = d3.select(this.el).select("#" + this.tag_id(tag, id))
    if val[0][0] == null
      return null
    else
      return val
  mget : (fld)->
    return @model.get(fld)
  mget_ref : (fld) ->
    return @model.get_ref(fld)

class TableView extends ContinuumView
  delegateEvents: ->
    @model.on('destroy', @remove, this)
    @model.on('change', @render, this)

  render : ->
    @$el.empty()
    @$el.append("<table></table>")
    @$el.find('table').append("<tr></tr>")
    headerrow = $(@$el.find('table').find('tr')[0])
    for column, idx in ['row'].concat(@mget('columns'))
      elem = $(_.template('<th class="tableelem tableheader">{{ name }}</th>',
        {'name' : column}))
      headerrow.append(elem)
    for row, idx in @mget('data')
      row_elem = $("<tr class='tablerow'></tr>")
      rownum = idx + @mget('data_slice')[0]
      for data in [rownum].concat(row)
        elem = $(_.template("<td class='tableelem'>{{val}}</td>",
          {'val':data}))
        row_elem.append(elem)
      @$el.find('table').append(row_elem)

    @render_pagination()

    if !@$el.is(":visible")
      @$el.dialog(
        close :  () =>
          @remove()
      )

  render_pagination : ->
    if @mget('offset') > 0
      node = $("<button>first</button>").css({'cursor' : 'pointer'})
      @$el.append(node)
      node.click(=>
        @model.load(0)
        return false
      )
      node = $("<button>previous</button>").css({'cursor' : 'pointer'})
      @$el.append(node)
      node.click(=>
        @model.load(_.max([@mget('offset') - @mget('chunksize'), 0]))
        return false
      )

    maxoffset = @mget('total_rows') - @mget('chunksize')
    if @mget('offset') < maxoffset
      node = $("<button>next</button>").css({'cursor' : 'pointer'})
      @$el.append(node)
      node.click(=>
        @model.load(_.min([
          @mget('offset') + @mget('chunksize'),
          maxoffset]))
        return false
      )
      node = $("<button>last</button>").css({'cursor' : 'pointer'})
      @$el.append(node)
      node.click(=>
        @model.load(maxoffset)
        return false
      )


class Table extends HasReference
  initialize : (attrs, options)->
    super(attrs, options)
    @register_property('offset', ['data_slice'],
      (data_slice) ->
        return data_slice[0]
      ,false)
    @register_property('chunksize', ['data_slice'],
      (data_slice) ->
        return data_slice[1] - data_slice[0]
      ,false)

  defaults :
    url : ""
    columns : []
    data : [[]]
    data_slice : [0, 100]
    total_rows : 0
  default_view : TableView
  load : (offset) ->
    @set('data_slice', [offset, offset + @get('chunksize')], {silent:true})
    $.get(@get('url'),
      {
        'data_slice' : JSON.stringify(@get('data_slice'))
      },
      (data) =>
        @set({'data' : JSON.parse(data)['data']})
    )

class Tables extends Backbone.Collection
  model : Table
  url : "/"

Continuum.register_collection('Table', new Tables())