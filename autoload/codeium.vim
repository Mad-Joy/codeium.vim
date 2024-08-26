let s:hlgroup = 'CodeiumSuggestion'
let s:request_nonce = 0
let s:using_codeium_status = 0

if !has('nvim')
  if empty(prop_type_get(s:hlgroup))
    call prop_type_add(s:hlgroup, {'highlight': s:hlgroup})
  endif
endif

let s:default_codeium_enabled = {
      \ 'help': 0,
      \ 'gitcommit': 0,
      \ 'gitrebase': 0,
      \ '.': 0}

function! codeium#Enabled() abort
  if !get(g:, 'codeium_enabled', v:true) || !get(b:, 'codeium_enabled', v:true)
    return v:false
  endif

  let codeium_filetypes = s:default_codeium_enabled
  call extend(codeium_filetypes, get(g:, 'codeium_filetypes', {}))

  let codeium_filetypes_disabled_by_default = get(g:, 'codeium_filetypes_disabled_by_default') || get(b:, 'codeium_filetypes_disabled_by_default')

  if !get(codeium_filetypes, &filetype, !codeium_filetypes_disabled_by_default)
    return v:false
  endif

  return v:true
endfunction

function! codeium#CompletionText() abort
  try
    return remove(s:, 'completion_text')
  catch
    return ''
  endtry
endfunction

function! s:CompletionInserter(current_completion, insert_text) abort
  let default = get(g:, 'codeium_tab_fallback', pumvisible() ? "\<C-N>" : "\t")

  if mode() !~# '^[iR]' || !exists('b:_codeium_completions')
    return default
  endif

  let current_completion = a:current_completion
  if current_completion is v:null
    return default
  endif

  let range = current_completion.range
  let suffix = get(current_completion, 'suffix', {})
  let suffix_text = get(suffix, 'text', '')
  let delta = get(suffix, 'deltaCursorOffset', 0)
  let start_offset = get(range, 'startOffset', 0)
  let end_offset = get(range, 'endOffset', 0)

  let text = a:insert_text . suffix_text
  if empty(text)
    return default
  endif

  let delete_range = ''
  if end_offset - start_offset > 0
    let delete_bytes = end_offset - start_offset
    let delete_chars = strchars(strpart(getline('.'), 0, delete_bytes))
    " We insert a space, escape to normal mode, then delete the inserted space.
    " This lets us "accept" any auto-inserted indentation which is otherwise
    " removed when we switch to normal mode.
    " \"_ sequence makes sure to delete to the void register.
    " This way our current yank is not overridden.
    let delete_range = " \<Esc>\"_x0\"_d" . delete_chars . 'li'
  endif

  let insert_text = "\<C-R>\<C-O>=codeium#CompletionText()\<CR>"
  let s:completion_text = text

  if delta == 0
    let cursor_text = ''
  else
    let cursor_text = "\<C-O>:exe 'go' line2byte(line('.'))+col('.')+(" . delta . ")\<CR>"
  endif
  call codeium#server#Request('AcceptCompletion', {'metadata': codeium#server#RequestMetadata(), 'completion_id': current_completion.completion.completionId})
  return delete_range . insert_text . cursor_text
endfunction

function! codeium#Accept() abort
  let current_completion = s:GetCurrentCompletionItem()
  return s:CompletionInserter(current_completion, current_completion is v:null ? '' : current_completion.completion.text)
endfunction

function! codeium#AcceptNextWord() abort
  let current_completion = s:GetCurrentCompletionItem()
  let completion_parts = current_completion is v:null ? [] : get(current_completion, 'completionParts', [])
  if len(completion_parts) == 0
    return ''
  endif
  let prefix_text = get(completion_parts[0], 'prefix', '')
  let completion_text = get(completion_parts[0], 'text', '')
  let next_word = matchstr(completion_text, '\v^\W*\k*')
  return s:CompletionInserter(current_completion, prefix_text . next_word)
endfunction

function! codeium#AcceptNextLine() abort
  let current_completion = s:GetCurrentCompletionItem()
  let text = current_completion is v:null ? '' : substitute(current_completion.completion.text, '\v\n.*$', '', '')
  return s:CompletionInserter(current_completion, text)
endfunction

function! s:HandleCompletionsResult(out, err, status) abort
  if exists('b:_codeium_completions')
    let response_text = join(a:out, '')
    try
      let response = json_decode(response_text)
      if get(response, 'code', v:null) isnot# v:null
        call codeium#log#Error('Invalid response from language server')
        call codeium#log#Error(response_text)
        call codeium#log#Error('stderr: ' . join(a:err, ''))
        call codeium#log#Exception()
        return
      endif
      let completionItems = get(response, 'completionItems', [])

      let b:_codeium_completions.items = completionItems
      let b:_codeium_completions.index = 0

      let b:_codeium_status = 2
      call s:RenderCurrentCompletion()
    catch
      call codeium#log#Error('Invalid response from language server')
      call codeium#log#Error(response_text)
      call codeium#log#Error('stderr: ' . join(a:err, ''))
      call codeium#log#Exception()
    endtry
  endif
endfunction

function! s:GetCurrentCompletionItem() abort
  if exists('b:_codeium_completions') &&
        \ has_key(b:_codeium_completions, 'items') &&
        \ has_key(b:_codeium_completions, 'index') &&
        \ b:_codeium_completions.index < len(b:_codeium_completions.items)
    return get(b:_codeium_completions.items, b:_codeium_completions.index)
  endif

  return v:null
endfunction

let s:nvim_extmark_ids = []

function! s:ClearCompletion() abort
  if has('nvim')
    let namespace = nvim_create_namespace('codeium')
    for id in s:nvim_extmark_ids
      call nvim_buf_del_extmark(0, namespace, id)
    endfor
    let s:nvim_extmark_ids = []
  else
    call prop_remove({'type': s:hlgroup, 'all': v:true})
  endif
endfunction

function! s:RenderCurrentCompletion() abort
  call s:ClearCompletion()
  call codeium#RedrawStatusLine()

  if mode() !~# '^[iR]'
    return ''
  endif
  if !get(g:, 'codeium_render', v:true)
    return
  endif

  let current_completion = s:GetCurrentCompletionItem()
  if current_completion is v:null
    return ''
  endif

  let parts = get(current_completion, 'completionParts', [])

  let idx = 0
  let inline_cumulative_cols = 0
  let diff = 0
  for part in parts
    let row = get(part, 'line', 0) + 1
    if row != line('.')
      call codeium#log#Warn('Ignoring completion, line number is not the current line.')
      continue
    endif
    if part.type ==# 'COMPLETION_PART_TYPE_INLINE'
      let _col = inline_cumulative_cols + len(get(part, 'prefix', '')) + 1
      let inline_cumulative_cols = _col - 1
    else
      let _col = len(get(part, 'prefix', '')) + 1
    endif
    let text = part.text

    if (part.type ==# 'COMPLETION_PART_TYPE_INLINE' && idx == 0) || part.type ==# 'COMPLETION_PART_TYPE_INLINE_MASK'
      let completion_prefix = get(part, 'prefix', '')
      let completion_line = completion_prefix . text
      let full_line = getline(row)
      let cursor_prefix = strpart(full_line, 0, col('.')-1)
      let matching_prefix = 0
      for i in range(len(completion_line))
        if i < len(full_line) && completion_line[i] ==# full_line[i]
          let matching_prefix += 1
        else
          break
        endif
      endfor
      if len(cursor_prefix) > len(completion_prefix)
        " Case where the cursor is beyond the completion (as if it added text).
        " We should always consume text regardless of matching or not.
        let diff = len(cursor_prefix) - len(completion_prefix)
      elseif len(cursor_prefix) < len(completion_prefix)
        " Case where the cursor is before the completion.
        " It could just be a cursor move, in which case the matching prefix goes
        " all the way to the completion prefix or beyond. Then we shouldn't do
        " anything.
        if matching_prefix >= len(completion_prefix)
          let diff = matching_prefix - len(completion_prefix)
        else
          let diff = len(cursor_prefix) - len(completion_prefix)
        endif
      endif
      if has('nvim') && diff > 0
        let diff = 0
      endif
      " Adjust completion. diff needs to be applied to all inline parts and is
      " done below.
      if diff < 0
        let text = completion_prefix[diff :] . text
      elseif diff > 0
        let text = text[diff :]
      endif
    endif

    if has('nvim')
      " Set priority high so that completions appear above LSP inlay hints
      let priority = get(b:, 'codeium_virtual_text_priority',
                  \ get(g:, 'codeium_virtual_text_priority', 65535))
      let _virtcol = _col " virtcol([row, _col+diff]) <madjoy>Exibe as sugestões uma linha a baixo do cursor para melhor integração com o nvim-cmp</madjoy>
      let data = {'id': idx + 1, 'hl_mode': 'combine', 'virt_text_win_col': _virtcol - 1, 'priority': priority }
      if part.type ==# 'COMPLETION_PART_TYPE_INLINE_MASK'
        let data.virt_text = [[text, s:hlgroup]]
      elseif part.type ==# 'COMPLETION_PART_TYPE_BLOCK'
        let lines = split(text, "\n", 1)
        if empty(lines[-1])
          call remove(lines, -1)
        endif
        let data.virt_lines = map(lines, { _, l -> [[l, s:hlgroup]] })
      else
        continue
      endif

      call add(s:nvim_extmark_ids, data.id)
      call nvim_buf_set_extmark(0, nvim_create_namespace('codeium'), row, 0, data) <madjoy>Exibe as sugestões na primeira coluna após o cursor para melhor integração com o nvim-cmp</madjoy>
    else
      if part.type ==# 'COMPLETION_PART_TYPE_INLINE'
        call prop_add(row, _col + diff, {'type': s:hlgroup, 'text': text})
      elseif part.type ==# 'COMPLETION_PART_TYPE_BLOCK'
        let text = split(part.text, "\n", 1)
        if empty(text[-1])
          call remove(text, -1)
        endif

        for line in text
          let num_leading_tabs = 0
          for c in split(line, '\zs')
            if c ==# "\t"
              let num_leading_tabs += 1
            else
              break
            endif
          endfor
          let line = repeat(' ', num_leading_tabs * shiftwidth()) . strpart(line, num_leading_tabs)
          call prop_add(row, 0, {'type': s:hlgroup, 'text_align': 'below', 'text': line})
        endfor
      endif
    endif

    let idx = idx + 1
  endfor
endfunction

function! codeium#Clear(...) abort
  let b:_codeium_status = 0
  call codeium#RedrawStatusLine()
  if exists('g:_codeium_timer')
    call timer_stop(remove(g:, '_codeium_timer'))
  endif

  " Cancel any existing request.
  if exists('b:_codeium_completions')
    let request_id = get(b:_codeium_completions, 'request_id', 0)
    if request_id > 0
      try
        call codeium#server#Request('CancelRequest', {'request_id': request_id})
      catch
        call codeium#log#Exception()
      endtry
    endif
    call s:RenderCurrentCompletion()
    unlet! b:_codeium_completions

  endif

  if a:0 == 0
    call s:RenderCurrentCompletion()
  endif
  return ''
endfunction

function! codeium#CycleCompletions(n) abort
  if s:GetCurrentCompletionItem() is v:null
    return
  endif

  let b:_codeium_completions.index += a:n
  let n_items = len(b:_codeium_completions.items)

  if b:_codeium_completions.index < 0
    let b:_codeium_completions.index += n_items
  endif

  let b:_codeium_completions.index %= n_items

  call s:RenderCurrentCompletion()
endfunction

function! codeium#Complete(...) abort
  if a:0 == 2
    let bufnr = a:1
    let timer = a:2

    if timer isnot# get(g:, '_codeium_timer', -1)
      return
    endif

    call remove(g:, '_codeium_timer')

    if mode() !=# 'i' || bufnr !=# bufnr('')
      return
    endif
  endif

  if exists('g:_codeium_timer')
    call timer_stop(remove(g:, '_codeium_timer'))
  endif

  if !codeium#Enabled()
    return
  endif

  if &encoding !=# 'latin1' && &encoding !=# 'utf-8'
    echoerr 'Only latin1 and utf-8 are supported'
    return
  endif

  let other_documents = []
  let current_bufnr = bufnr('%')
  let loaded_buffers = getbufinfo({'bufloaded':1})
  for buf in loaded_buffers
    if buf.bufnr != current_bufnr && getbufvar(buf.bufnr, '&filetype') !=# ''
      call add(other_documents, codeium#doc#GetDocument(buf.bufnr, 1, 1))
    endif
  endfor

  let data = {
        \ 'metadata': codeium#server#RequestMetadata(),
        \ 'document': codeium#doc#GetDocument(bufnr(), line('.'), col('.')),
        \ 'editor_options': codeium#doc#GetEditorOptions(),
        \ 'other_documents': other_documents
        \ }

  if exists('b:_codeium_completions.request_data') && b:_codeium_completions.request_data ==# data
    return
  endif

  " Add request id after we check for identical data.
  let request_data = deepcopy(data)

  let s:request_nonce += 1
  let request_id = s:request_nonce
  let data.metadata.request_id = request_id

  try
    let b:_codeium_status = 1
    let request_job = codeium#server#Request('GetCompletions', data, function('s:HandleCompletionsResult', []))

    let b:_codeium_completions = {
          \ 'request_data': request_data,
          \ 'request_id': request_id,
          \ 'job': request_job
          \ }
  catch
    call codeium#log#Exception()
  endtry
endfunction

function! codeium#DebouncedComplete(...) abort
  call codeium#Clear()
  if get(g:, 'codeium_manual', v:false)
    return
  endif
  let current_buf = bufnr('')
  let delay = get(g:, 'codeium_idle_delay', 75)
  let g:_codeium_timer = timer_start(delay, function('codeium#Complete', [current_buf]))
endfunction

function! codeium#CycleOrComplete() abort
  if s:GetCurrentCompletionItem() is v:null
    call codeium#Complete()
  else
    call codeium#CycleCompletions(1)
  endif
endfunction

function! s:LaunchChat(out, err, status) abort
  let l:metadata = codeium#server#RequestMetadata()
  let l:processes = json_decode(join(a:out, ''))
  let l:chat_port = l:processes['chatClientPort']
  let l:ws_port = l:processes['chatWebServerPort']

  let config = get(g:, 'codeium_server_config', {})
  let l:has_enterprise_extension = 'false'
  if has_key(config, 'api_url') && !empty(config.api_url)
    let l:has_enterprise_extension = 'true'
  endif

  " Hard-coded to English locale and allowed telemetry.
  let l:url = 'http://127.0.0.1:' . l:chat_port . '/?' . 'api_key=' . l:metadata.api_key . '&ide_name=' . l:metadata.ide_name . '&ide_version=' . l:metadata.ide_version . '&extension_name=' . l:metadata.extension_name . '&extension_version=' . l:metadata.extension_version . '&web_server_url=ws://127.0.0.1:' . l:ws_port . '&has_enterprise_extension=' . l:has_enterprise_extension . '&app_name=Vim&locale=en&ide_telemetry_enabled=true&has_index_service=true'
  let l:browser = codeium#command#BrowserCommand()
  let opened_browser = v:false
  if !empty(browser)
    echomsg 'Navigating to ' . l:url
    try
      call system(l:browser . ' ' . '"' . l:url . '"')
      if v:shell_error is# 0
        let l:opened_browser = v:true
      endif
    catch
    endtry

    if !l:opened_browser
      echomsg 'Failed to open browser. Please go to the link above.'
    endif
  else
    echomsg 'No available browser found. Please go to ' . l:url
  endif
endfunction

let g:codeium_workspace_root_hints = ['.bzr','.git','.hg','.svn','_FOSSIL_','package.json']
function! s:GetProjectRoot() abort
  let l:last_dir = ''
  let l:dir = getcwd()
  while l:dir != l:last_dir
    for l:root_hint in g:codeium_workspace_root_hints
      let l:hint = l:dir . '/' . l:root_hint
      if isdirectory(l:hint) || filereadable(l:hint)
        return l:dir
      endif
    endfor
    let l:last_dir = l:dir
    let l:dir = fnamemodify(l:dir, ':h')
  endwhile
  return getcwd()
endfunction

" This assumes a single workspace is involved per Vim session, for now.
let s:codeium_workspace_indexed = v:false
function! codeium#AddTrackedWorkspace() abort
  if (!codeium#Enabled() || s:codeium_workspace_indexed)
    return
  endif
  let s:codeium_workspace_indexed = v:true
  try
    call codeium#server#Request('AddTrackedWorkspace', {'workspace': s:GetProjectRoot()})
  catch
    call codeium#log#Exception()
  endtry
endfunction

function! codeium#Chat() abort
  if (!codeium#Enabled())
    return
  endif
  try
    call codeium#server#Request('GetProcesses', codeium#server#RequestMetadata(), function('s:LaunchChat', []))
    call codeium#AddTrackedWorkspace()
  catch
    call codeium#log#Exception()
  endtry
endfunction

function! codeium#GetStatusString(...) abort
  let s:using_codeium_status = 1
  if (!codeium#Enabled())
    return 'OFF'
  endif
  if mode() !~# '^[iR]'
    return ' ON'
  endif
  if exists('b:_codeium_status') && b:_codeium_status > 0
    if b:_codeium_status == 2
      if exists('b:_codeium_completions') &&
            \ has_key(b:_codeium_completions, 'items') &&
            \ has_key(b:_codeium_completions, 'index')
        if len(b:_codeium_completions.items) > 0
          return printf('%d/%d', b:_codeium_completions.index + 1, len(b:_codeium_completions.items))
        else
          return ' 0 '
        endif
      endif
    endif
    if b:_codeium_status == 1
      return ' * '
    endif
    return ' 0 '
  endif
  return '   '
endfunction

function! codeium#RedrawStatusLine() abort
  if s:using_codeium_status
    redrawstatus
  endif
endfunction

function! codeium#ServerLeave() abort
  if !exists('g:codeium_server_job') || g:codeium_server_job is v:null
    return
  endif

  if has('nvim')
    call jobstop(g:codeium_server_job)
  else
    call job_stop(g:codeium_server_job)
  endif
endfunction
