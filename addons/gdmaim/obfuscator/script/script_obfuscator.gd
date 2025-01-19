extends RefCounted


const _Logger := preload("../../logger.gd")
const _Settings := preload("../../settings.gd")
const PreprocessorHints := preload("preprocessor_hints.gd")
const SymbolTable := preload("../symbol_table.gd")
const Parser := preload("parser/parser.gd")
const Token := preload("tokenizer/token.gd")
const Tokenizer := preload("tokenizer/tokenizer.gd")
const AST := preload("parser/ast.gd")

var path : String
var source_code : String
var generated_code : String
var parser : Parser
var tokenizer : Tokenizer

var _symbol_table : SymbolTable
var _ast : AST.ASTNode


func _init(path : String) -> void:
	self.path = path


func parse(source_code : String, symbol_table : SymbolTable, autoload_symbol : SymbolTable.Symbol = null) -> void:
	self.source_code = source_code
	_symbol_table = symbol_table
	tokenizer = Tokenizer.new()
	tokenizer.read(source_code)
	parser = Parser.new()
	_ast = parser.read(tokenizer, symbol_table, autoload_symbol)


func run(features : PackedStringArray) -> bool:
	if !parser:
		_Logger.write("ERROR: ScriptObfuscator.run() - No parsed data!")
		return false
	
	tokenizer.reset()
	while !tokenizer.is_eof():
		var token : Token = tokenizer.get_next()
		var next_token : Token = tokenizer.peek()
		var line : Tokenizer.Line = tokenizer.get_output_line(token.line)
		var prev_line : Tokenizer.Line = tokenizer.get_output_line(token.line-1)
		
		if _Settings.current.obfuscation_enabled:
			if line.has_hint(PreprocessorHints.OBFUSCATE_STRINGS):
				_string_obfuscation(token)
			_string_param_obfuscation(token, next_token)
		
		if !_Settings.current.feature_filters:
			continue
		
		if prev_line and prev_line.has_hint(PreprocessorHints.FEATURE_FUNC):
			_func_feature_filter(token, line, prev_line.get_hint_args(PreprocessorHints.FEATURE_FUNC), features)
	
	if _Settings.current.obfuscation_enabled and _Settings.current.shuffle_top_level:
		_shuffle_toplevel()
	
	_strip_code()
	_combine_statement_lines()
	
	return true


func generate_source_code() -> String:
	generated_code = tokenizer.generate_source_code()
	return generated_code


func generate_line_mappings() -> Array[Dictionary]:
	var mappings_in : Dictionary
	var mappings_out : Dictionary
	var output_lines : Array[Tokenizer.Line] = tokenizer.get_output_lines()
	for i in output_lines.size():
		var line : Tokenizer.Line = output_lines[i]
		for token in line.tokens:
			if token.line != -1:
				mappings_in[token.line] = i
				mappings_out[i] = token.line
				break
	#HACK it works?
	mappings_in[tokenizer.line_count-1] = output_lines.size()
	mappings_out[output_lines.size()] = tokenizer.line_count-1
	
	var last_valid : int = 0
	for i in tokenizer.line_count:
		var from : int = mappings_in.get(i, last_valid)
		last_valid = from
		mappings_in[i] = from
	
	return [mappings_in, mappings_out]


func get_class_symbol() -> SymbolTable.Symbol:
	return parser.get_class_symbol() if parser else null


func _string_obfuscation(token : Token) -> void:
	if !token.is_string_literal():
		return
	
	var str : String = token.get_value()
	token.set_value(str[0] + _symbol_table.obfuscate_string_global(str.substr(1, str.length() - 2)) + str[-1])


func _string_param_obfuscation(token : Token, next_token : Token) -> void:
	if !token.symbol or !next_token or !next_token.is_punctuator("("):
		return
	
	var symbol : SymbolTable.Symbol = token.symbol
	if !symbol.has_string_params():
		return
	
	var param : int = 0
	var pth : int = 0
	var maybe_str_param : bool = true
	while !tokenizer.is_eof():
		token = tokenizer.get_next()
		if token.is_punctuator():
			if token.has_value("("):
				pth += 1
			elif token.has_value(")"):
				pth -= 1
				if pth <= 0:
					break
			elif token.has_value(",") and pth == 1:
				param += 1
				maybe_str_param = true
			continue
		elif maybe_str_param and token.is_string_literal() and symbol.is_string_param(param):
			var str : String = token.get_value()
			token.set_value(str[0] + _symbol_table.obfuscate_string_global(str.substr(1, str.length() - 2)) + str[-1])
		maybe_str_param = false


func _func_feature_filter(token : Token, line : Tokenizer.Line, feature : String, features : PackedStringArray) -> void:
	if !token.is_keyword("func"):
		return
	
	if !features.has(feature):
		var indentation : int = line.get_indentation()
		var func_path : String = path.get_basename() + "." + tokenizer.get_next().get_value()#tokenizer.get_next().symbol.get_source_name()
		var func_body : String = 'printerr("ERROR: illegal call to ' + "'" + func_path + "'!" + '");'
		var pth : int = 0
		while !tokenizer.is_eof():
			token = tokenizer.get_next()
			if token.is_punctuator("("):
				pth += 1
			elif token.is_punctuator(")"):
				pth -= 1
				if pth <= 0:
					break
		token = tokenizer.get_next()
		if token.is_operator("->"):
			token = tokenizer.get_next()
			var ret_type : String = token.get_value()
			const ret_code : Dictionary = {
				"bool": "return false",
				"int": "return 0",
				"float": "return 0.0",
				"String": 'return ""',
				"Array": "return []",
				"Array[int]": "return []",
				"Array[float]": "return []",
				"Dictionary": "return {}",
				"void": "",
			}
			func_body += ret_code.get(ret_type, "return null")
		var line_idx_from : int = tokenizer.find_output_line(line)
		var line_idx : int = line_idx_from + 2
		var last_valid : int = -1
		tokenizer.get_output_line(line_idx_from + 1).clear_tokens()
		tokenizer.get_output_line(line_idx_from + 1).insert_token(1, Token.new(Token.Type.KEYWORD, func_body, 0, line_idx_from + 1))
		while line_idx < tokenizer.get_output_line_count():
			var tline : Tokenizer.Line = tokenizer.get_output_line(line_idx)
			if tline.has_statement():
				if tline.get_indentation() <= indentation:
					break
				last_valid = line_idx
			if tline.tokens:
				tokenizer.seek_token(tline.tokens[0])
			line_idx += 1
		if last_valid != -1:
			for l in range(line_idx_from + 2, last_valid + 1):
				tokenizer.get_output_line(l).clear_tokens()


func _shuffle_toplevel() -> void:
	var lines : Array[Tokenizer.Line] = tokenizer.get_output_lines()
	var top_block : Array
	var on_ready : Array[Array] = []
	var blocks : Array[Array] = []
	var current_block : Array
	var current_is_onready : bool
	
	var add_block = func(block : Array, is_onready : bool):
		if block.is_empty(): return
		if is_onready:
			on_ready.append(block)
		else:
			blocks.append(block)
	
	for i in lines.size():
		var line : Tokenizer.Line = lines[i]
		var prev_line : Tokenizer.Line = lines[i - 1] if i >= 1 else null
		var starter_token : Token = line.tokens[0] if line.tokens else null
		var prev_starter_token : Token = prev_line.tokens[0] if prev_line and prev_line.tokens else null
		if starter_token and ["@icon", "@tool", "class_name", "extends"].has(starter_token.get_value()):
			top_block.append(line)
			continue
		if starter_token and starter_token.get_value() == "@onready":
			add_block.call(current_block, current_is_onready)
			current_block = []
			current_is_onready = true
		elif line.get_indentation() == 0 and starter_token and (starter_token.is_keyword() or starter_token.is_annotation()) and (!prev_starter_token or (!prev_starter_token.has_value("@rpc") and !(prev_starter_token.get_value().begins_with("@export") and !prev_line.has_token_value("var")))):
			add_block.call(current_block, current_is_onready)
			current_block = []
			current_is_onready = false
		
		current_block.append(line)
	
	add_block.call(current_block, current_is_onready)
	
	var w_blocks : Dictionary
	var random := RandomNumberGenerator.new()
	var line_seeds : Dictionary
	for block in blocks:
		var line_seed : int = 0
		if block:
			line_seed = hash(block[0].to_string())
			line_seeds[line_seed] = line_seeds.get(line_seed, -1) + 1
			line_seed += line_seeds[line_seed]
		random.seed = hash(path) + path.length() + _symbol_table._seed + line_seed
		w_blocks[block] = random.randi()
	blocks.sort_custom((func(a, b): return w_blocks[a] > w_blocks[b]))
	
	if on_ready:
		var idx : int = 0
		var max_spacing : int = mini(blocks.size() / on_ready.size() * 2, blocks.size() + 1)
		random.seed = hash(path) + path.length() + _symbol_table._seed
		for block in on_ready:
			if max_spacing:
				idx += maxi(1, random.randi() % max_spacing)
			blocks.insert(mini(idx, blocks.size()), block)
	
	lines.clear()
	for block in [top_block] + blocks:
		lines.append_array(block)


func _strip_code() -> void:
	var regex := RegEx.new()
	if _Settings.current.regex_filter_enabled and _Settings.current.regex_filter:
		regex.compile(_Settings.current.regex_filter)
	
	var lines : Array[Tokenizer.Line] = tokenizer.get_output_lines()
	for l in range(lines.size() - 1, -1, -1):
		var line : Tokenizer.Line = lines[l]
		
		if _Settings.current.strip_comments or _Settings.current.strip_extraneous_spacing:
			for i in range(line.tokens.size() - 1, -1, -1):
				var token : Token = line.tokens[i]
				
				# Strip comments
				if _Settings.current.strip_comments and token.type == Token.Type.COMMENT:
					line.remove_token(i)
					continue
				
				# Strip extraneous spacing
				if _Settings.current.strip_extraneous_spacing:
					if token.type == Token.Type.INDENTATION and (i == line.tokens.size()-1 or line.tokens[i+1].type == Token.Type.LINE_BREAK):
						line.remove_token(i)
						continue
					elif token.type == Token.Type.WHITESPACE:
						var prev_type : int = line.tokens[i-1].type
						var next_type : int = line.tokens[i+1].type if i+1 < line.tokens.size() else Token.Type.NONE
						if i == 0 or prev_type == Token.Type.OPERATOR or prev_type == Token.Type.PUNCTUATOR or next_type == Token.Type.OPERATOR or next_type == Token.Type.PUNCTUATOR:
							line.remove_token(i)
							continue
		
		# Strip empty lines
		if _Settings.current.strip_empty_lines and str(line).replace(" ", "").replace("\n", "").replace("\t", "").replace(";", "").is_empty():
			tokenizer.remove_output_line(l)
			continue
		
		# Strip lines matching RegEx
		if regex.is_valid() and regex.search(str(line)):
			tokenizer.remove_output_line(l)
			continue


func _combine_statement_lines() -> void:
	if not _Settings.current.inline_statements: return
	
	# Note: Use AST for more confident algorithm
	
	var lines : Array[Tokenizer.Line] = tokenizer.get_output_lines()
	if lines.is_empty(): return
	
	var active_line : Tokenizer.Line = lines[0]
	var start_new_scope : bool = false
	var require_separate_line : bool = false
	var i : int = 1
	
	var scope_indents : Array[String] = []
	var scope_start_idx : Array[int] = []
	var scope_can_inline : Array[bool] = []
	var scope_brackets_count : int = 0
	
	var empty_line_counter : int = 0
	var prev_line_brackets_count : int = 0
	var prev_line_decorator : bool = false
	
	# Check if the file starts with "extends" to handle the inconsistent requirement it has
	if active_line.tokens[0].is_keyword() and active_line.tokens[0].get_value() == "extends":
		active_line = null
	
	while i <= lines.size():
		var end_of_file : bool = i >= lines.size()
		var line : Tokenizer.Line = lines[i] if !end_of_file else Tokenizer.Line.new([Token.new(Token.Type.WHITESPACE, '', 0, i)])
		i += 1
		
		var first_token : Token = line.tokens[0] if !line.tokens.is_empty() else Token.new(Token.Type.LINE_BREAK, '\n', 0, i-1)
		var last_token : Token = line.tokens[line.tokens.size() - 2] if line.tokens.size() > 2 else Token.new(Token.Type.LINE_BREAK, '\n', 0, i-1)
		var is_indented : bool = first_token.is_whitespace() or first_token.is_indentation()
		var current_scope : String = scope_indents[scope_indents.size()-1] if !scope_indents.is_empty() else ''
		
		# An empty line is any whitespace or tab only line that isn't the last fake line
		var line_empty := not end_of_file
		if line_empty:
			for token in line.tokens:
				if !token.is_of_type(Token.Type.LINE_BREAK | Token.Type.WHITESPACE | Token.Type.INDENTATION | Token.Type.COMMENT):
					line_empty = false
					break
		
		var current_indent : String = first_token.get_value() if !line_empty else current_scope
		
		var process_curent_line : bool = true
		
		# Start of a new anchor line, which will kept being expanded
		if active_line == null:
			active_line = line
			if is_indented and current_scope.length() < current_indent.length():  # If it's indented more (not less), track the indent
				scope_indents.append(current_indent)
				scope_start_idx.append(i-1)
				scope_can_inline.append(not require_separate_line)
			process_curent_line = false
		
		# Scope change (whilst not in brackets) => Reducing indents
		if prev_line_brackets_count == 0 and !scope_indents.is_empty() and current_indent != current_scope and not start_new_scope:
			active_line = line
			var internal_indent_index = scope_indents.size()-1
			# Closing (one/several) scopes
			while !scope_indents.is_empty() and scope_indents[internal_indent_index] != current_indent:
				# Check if the scope resulting inside code is one line -> assume we can inline the entire line then
				# Since this runs on a line that changes scope, aka non empty line, we need to subtract any empty lines that were between the last scope and this new one
				#    so the condition still checks out on a difference of 2
				var current_scope_start_idx := scope_start_idx[internal_indent_index]
				var head_line : Tokenizer.Line = lines[current_scope_start_idx-1]
				# Make sure if we will merge, it will not be into a comment!
				# Also check if we're allowed to inline this scope, not all scopes can
				if i - current_scope_start_idx - empty_line_counter == 2 and (head_line.tokens.size() > 2 and not head_line.tokens[head_line.tokens.size()-2].is_comment()) and scope_can_inline[internal_indent_index]:
					# If so, we can merge them without any separator
					head_line.remove_token(head_line.tokens.size() - 1)
					for token_idx in range(1, lines[current_scope_start_idx].tokens.size()):  # We skip the first token aka indent
						var token : Token = lines[current_scope_start_idx].tokens[token_idx]
						token.line = head_line.tokens[0].line
						head_line.add_token(token)
					# Remove line from tokenizer to keep sanitary data
					tokenizer.remove_output_line(current_scope_start_idx)
					i -= 1
				
				scope_indents.remove_at(internal_indent_index)
				scope_start_idx.remove_at(internal_indent_index)
				scope_can_inline.remove_at(internal_indent_index)
				internal_indent_index -= 1
			process_curent_line = false
		
		# Clear leading indent
		if process_curent_line and is_indented:
			line.remove_token(0)
		
		# Some keywords (like export in certain scenarios or @export_group) MUST end in a new line
		var standalone_annotations := (first_token.is_keyword() or first_token.is_annotation()) and first_token.get_value() in ["extends", "@export_group", "@export_subgroup"]
		# Search for unfinished statements, such as @annotations that dont follow the statement they're annotating in the same line or keywords like `extends` and `class_name`
		var top_level_class_annotation := (first_token.is_keyword() or first_token.is_annotation()) and first_token.get_value() in ["extends", "class_name", "@tool", "@icon"]
		var is_line_extending_prev_line = top_level_class_annotation or prev_line_decorator
		
		# Whitespace tracking
		var line_still_indenting := true
		# Control tracking
		var line_has_control := false
		var line_has_inline_control := false
		# Get set tracking
		var line_getset_conditions := 0  # 0: nothing, 1: 'var' keyword
		var line_has_getset := false
		# Get set function tracking
		var line_getset_function_conditions := 0  # 0: nothing, 1: 'set' keyword, 2: 'set(' or 'get'. A ':' punctuation will most likely mean a getset function
		var line_has_getset_function := false
		# Inner class tracking
		var line_has_class := false
		# Discover what type of statements exist in this line, such as inline if blocks or variables with pending getters setters
		for token in line.tokens:
			if token.type == Token.Type.PUNCTUATOR and token.get_value() in "[{(":
				scope_brackets_count += 1
				if line_getset_function_conditions == 1: line_getset_function_conditions = 2
			elif token.type == Token.Type.PUNCTUATOR and token.get_value() in ")}]":
				scope_brackets_count -= 1
			
			elif token.type == Token.Type.PUNCTUATOR and token.get_value() == ":":
				if scope_brackets_count > 0: continue
				if line_has_control: line_has_inline_control = true
				if line_getset_function_conditions == 2: line_has_getset_function = true
			elif token.type == Token.Type.PUNCTUATOR and token.get_value() == ";":
				line_getset_conditions = 0
				line_getset_function_conditions = 0
			
			elif token.type == Token.Type.KEYWORD and token.get_value() in ["if", "else", "elif", "while", "for", "match", "func"]:
				line_has_control = true
			elif token.type == Token.Type.KEYWORD and token.get_value() == 'var':
				line_getset_conditions = 1
			elif token.type == Token.Type.KEYWORD and token.get_value() == 'class':
				line_has_class = true
			elif token.type == Token.Type.SYMBOL and token.get_value() == 'get':
				if line_still_indenting: line_getset_function_conditions = 2
			elif token.type == Token.Type.SYMBOL and token.get_value() == 'set':
				if line_still_indenting: line_getset_function_conditions = 1
			
			if line_still_indenting and (!token.is_whitespace() and token.is_indentation()):
				line_still_indenting = false
		
		# The next scope defines a getter or setter if the line starts with a 'get' or 'set' and has a colon
		if scope_brackets_count == 0 and line_getset_conditions == 1 and last_token.is_punctuator(':'):
			line_has_getset = true
		
		# If the line is the start of a new scope, do not run this because it will try to add to a previous scope
		# Done like this so lines that start a scope can still count brackets and be checked if they themselves open a scope
		if process_curent_line and not line_empty:
			var newline_token : Token = active_line.tokens[active_line.tokens.size() - 1]
			# Don't add semicolons if inside of a bracket structure, just remove newline
			# (it's affecting the active_line, which is before this current line, so use prev_line_brackets_count)
			if prev_line_brackets_count == 0 and not is_line_extending_prev_line:
				newline_token.type = Token.Type.PUNCTUATOR
				newline_token.set_value(';')
			# GDScript top level decorators should just be separated by space
			# Additionally check if the previous line ends in a punctuator, such as a ). Then don't run this as this will add a space, the else will remove any whitespace
			elif is_line_extending_prev_line and (active_line.tokens.size() >= 2 and not active_line.tokens[active_line.tokens.size()-2].is_punctuator()):
				newline_token.type = Token.Type.WHITESPACE
				newline_token.set_value(' ')
			else:
				active_line.remove_token(active_line.tokens.size() - 1)
		
			# Keep clean tokenizer data by adding tokens to the active_line
			for token in line.tokens:
				token.line = first_token.line
				active_line.add_token(token)
			if !end_of_file:
				i -= 1
				tokenizer.remove_output_line(i)
		
		require_separate_line = false
		start_new_scope = false
		
		# Fulfill newline requirement
		if standalone_annotations or line_empty or last_token.is_comment():
			active_line = null
		
		# Getters setters scope must be in its own indented scope, can't be inline
		# Inner classes are less error prone if they're not inline too
		if line_has_getset or line_has_class:
			active_line = null
			start_new_scope = true
			require_separate_line = true
		
		# The statement opens a new scope -> it needs to be indented so it can be exited
		# Also check for in-line control statements as to prevent statements from flooding into the inline scope
		if (scope_brackets_count == 0 and last_token.is_punctuator(':')) or line_has_inline_control or line_has_getset_function:
			active_line = null
			start_new_scope = true
		
		# Check if the line has a decorator (with optional params in parentheses) but no following statement
		# The next line will need to extend this without adding a ; punctuation
		if not line_empty and prev_line_brackets_count == 0: prev_line_decorator = false
		if first_token.is_annotation():
			prev_line_decorator = true
			var _open_annotation_brackets := 0
			# Look for any non-whitespace token that isn't in brackets. If exists the annotation is followed by something in the same line
			for anno_i in range(1, line.tokens.size()):
				var token : Token = line.tokens[anno_i]
				if token.is_of_type(Token.Type.WHITESPACE | Token.Type.LINE_BREAK | Token.Type.INDENTATION | Token.Type.COMMENT): continue
				elif token.is_punctuator('('): _open_annotation_brackets += 1
				elif token.is_punctuator(')'): _open_annotation_brackets -= 1
				elif _open_annotation_brackets == 0: prev_line_decorator = false; break
		
		prev_line_brackets_count = scope_brackets_count
		
		if line_empty:
			empty_line_counter += 1
		else:
			empty_line_counter = 0
