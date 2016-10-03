/*-
 * Copyright (c) 2015-2016 Adam Bieńkowski
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 *
 * Authored by: Adam Bieńkowski <donadigos159@gmail.com>
 */

namespace IDE {
    public class EditorView : Gtk.Box, DocumentManager {
        private ValaIndex index;

        private Project project;
        private List<Document> documents;

        private TerminalWidget terminal_widget;

        private Granite.Widgets.DynamicNotebook notebook;
        private Granite.Widgets.Sidebar sidebar;
        private Gtk.Paned vertical_paned;

        private Gtk.Label location_label;

        private ReportWidget report_widget;
        private InfoWindow info_window;

        private ValaDocumentProvider provider;

        private Granite.Widgets.ModeButton mode_button;
        private Gtk.Stack bottom_stack;

        private bool document_recently_changed = false;
        private uint update_report_view_timeout_id = 0;

        private int report_widget_id = -1;
        private int terminal_widget_id = -1;
        private int build_output_widget_id = -1;

        construct {
            orientation = Gtk.Orientation.VERTICAL;

            index = new ValaIndex ();
            provider = new ValaDocumentProvider (this);

            documents = new List<Document> ();

            terminal_widget = new TerminalWidget ();

            notebook = new Granite.Widgets.DynamicNotebook ();
            notebook.expand = true;
            notebook.show_tabs = true;
            notebook.allow_drag = true;
            notebook.allow_pinning = true;
            notebook.allow_new_window = true;
            notebook.allow_duplication = false;
            notebook.add_button_visible = true;
            notebook.new_tab_requested.connect (add_new_document);
            notebook.tab_switched.connect (on_tab_switched);
            notebook.tab_removed.connect (tab_removed);
            notebook.add_button_tooltip = _("New empty document");

            location_label = new Gtk.Label (null);

            var info_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            info_box.add (location_label);

            sidebar = new Granite.Widgets.Sidebar ();
            info_window = new InfoWindow ();

            report_widget = new ReportWidget ();
            report_widget.jump_to.connect (on_jump_to);

            var bottom_bar = new Gtk.Grid ();

            bottom_stack = new Gtk.Stack ();
            bottom_stack.transition_type = Gtk.StackTransitionType.OVER_RIGHT_LEFT;
            bottom_stack.add_named (report_widget, Constants.REPORT_VIEW_NAME);
            bottom_stack.add_named (terminal_widget, Constants.TERMINAL_VIEW_NAME);

            mode_button = new Granite.Widgets.ModeButton ();
            mode_button.mode_changed.connect (on_mode_changed);
            mode_button.orientation = Gtk.Orientation.VERTICAL;
            mode_button.valign = Gtk.Align.START;

            report_widget_id = mode_button.append_icon ("dialog-information-symbolic", Gtk.IconSize.MENU);
            terminal_widget_id = mode_button.append_icon ("utilities-terminal-symbolic", Gtk.IconSize.MENU);
            build_output_widget_id = mode_button.append_icon ("open-menu-symbolic", Gtk.IconSize.MENU);

            style_mode_button_children ();

            mode_button.selected = report_widget_id;

            bottom_bar.attach (mode_button, 0, 0, 1, 1);
            bottom_bar.attach (new Gtk.Separator (Gtk.Orientation.VERTICAL), 1, 0, 1, 1);
            bottom_bar.attach (bottom_stack, 2, 0, 1, 1);

            var scrolled = new Gtk.ScrolledWindow (null, null);
            scrolled.min_content_width = 200;
            scrolled.add (sidebar);

            vertical_paned = new Gtk.Paned (Gtk.Orientation.VERTICAL);
            vertical_paned.pack1 (notebook, true, false);
            vertical_paned.pack2 (bottom_bar, false, false);

            var horizontal_paned = new Gtk.Paned (Gtk.Orientation.HORIZONTAL);
            horizontal_paned.pack1 (scrolled, false, false);
            horizontal_paned.pack2 (vertical_paned, true, true);

            update_report_view_timeout_id = Timeout.add (2000, () => {
                clear_view_tags ();
                if (index.parsing) {
                    return true;
                }

                if (document_recently_changed) {
                    document_recently_changed = false;
                    return true;
                }

                update_report_view (index.report);
                update_view_tags (index.report);
                return true;
            });

            add (horizontal_paned);
            show_all ();
        }

        public EditorView.from_project (Project project) {
            this.project = project;
            process_root_directory ();
        }

        public void add_new_document () {
            var document = new Document.empty ();
            add_document (document, true);
        }

        private void process_root_directory () {
            if (project == null) {
                return;
            }

            var file = File.new_for_path (project.root_path);
            process_directory (file);
            sidebar.show_all ();
        }

        private void on_mode_changed () {
            if (mode_button.selected == report_widget_id) {
                bottom_stack.visible_child_name = Constants.REPORT_VIEW_NAME;
            } else if (mode_button.selected == terminal_widget_id) {
                bottom_stack.visible_child_name = Constants.TERMINAL_VIEW_NAME;
            }
        }

        private void style_mode_button_children () {
            foreach (var child in mode_button.get_children ()) {
                if (child is Gtk.ToggleButton) {
                    child.get_style_context ().add_class ("ide-bottom-view");
                }
            }
        }

        private void process_directory (File directory, Granite.Widgets.SidebarHeader? previous_header = null) {
            var enumerator = directory.enumerate_children ("standard::*", FileQueryInfoFlags.NONE, null);

            Granite.Widgets.SidebarHeader? header = previous_header;
            FileInfo? info;
            while ((info = enumerator.next_file ()) != null) {
                if (info.get_name ().has_prefix (".")) {
                    continue;
                }

                var subfile = directory.resolve_relative_path (info.get_name ());
                if (info.get_file_type () == FileType.DIRECTORY) {
                    header = new Granite.Widgets.SidebarHeader (info.get_name ());
                    header.row_activated.connect (on_row_activated);

                    if (previous_header != null) {
                        /* WIP */
                        // header.add_child (header);
                    } else {
                        sidebar.add (header);
                    }

                    process_directory (subfile, header);
                } else {
                    string icon_name;
                    var icon = (ThemedIcon)info.get_icon ();
                    string[] names = icon.get_names ();
                    if (names.length > 0 && Gtk.IconTheme.get_default ().has_icon (names[0])) {
                        icon_name = icon.get_names ()[0];
                    } else {
                        icon_name = "application-octet-stream";
                    }

                    var row = new SidebarFileRow (info.get_name (), icon_name);
                    row.filename = subfile.get_path ();
                    if (header != null) {
                        header.add_child (row);
                    } else {
                        sidebar.add (row);
                    }
                }
            }
        }

        private void on_row_activated (Gtk.ListBoxRow child) {
            var row = (SidebarFileRow)child;
            var document = new Document (File.new_for_path (row.filename), null);
            add_document (document, true);
        }

        private void on_jump_to (string filename, int line, int column) {
            var document = get_document_by_filename (filename);
            if (document == null) {
                document = new Document (File.new_for_path (filename), null);
                add_document (document, false);
            }

            notebook.current = document;

            var source_buffer = document.editor_window.source_buffer;

            Gtk.TextIter iter;
            source_buffer.get_iter_at_mark (out iter, source_buffer.get_insert ());

            iter.set_line (line);

            document.editor_window.source_view.scroll_to_iter (iter, 0.4, true, 0, 0);

            iter.set_line_offset (column);
            document.editor_window.source_buffer.place_cursor (iter);
            document.grab_focus ();
        }

        private void tab_removed (Granite.Widgets.Tab tab) {
            remove_document ((Document)tab);
        }

        private void on_tab_switched (Granite.Widgets.Tab? old_tab, Granite.Widgets.Tab new_tab) {
            update_location_label ();
        }

        public void remove_document (Document document) {
            document.close ();

            if (notebook.n_tabs == 0) {
                // TODO: do not quit here
                Gtk.main_quit ();
            }
        }

        public void add_document (Document document, bool focus = true) {
            document.load ();

            if (document.get_is_vala_source ()) {
                index.add_document (document);    
            }

            document.editor_window.source_view.completion.add_provider (provider);
            document.content_changed.connect (() => document_content_changed (document));

            document.editor_window.source_buffer.notify["cursor-position"].connect (() => update_location_label ());
            document.editor_window.close_info_window.connect (() => info_window.hide ());
            document.editor_window.show_info_window.connect ((iter, x, y) => on_show_info_window (document, iter, x, y));

            documents.append (document);
            notebook.insert_tab (document, notebook.n_tabs);

            if (focus) {
                notebook.current = document;
            }

            queue_parse ();
        }

        public Document? get_current_document () {
            return (Document)notebook.current;
        }

        public ValaIndex? get_index () {
            return index;
        }

        public Project? get_project () {
            return project;
        }

        public void queue_parse () {
            index.queue_parse ();
        }

        private void document_content_changed (Document document) {
            index.update_document_content (document);
            document_recently_changed = true;
        }

        private void update_location_label () {
            var current = get_current_document ();
            if (current == null) {
                // TODO: hide location label
                return;
            }

            // TODO: show location label
            report_widget.location_label.label = _("Line %i, Column %i".printf (current.current_line + 1, current.current_column));
        }

        private void update_report_view (Report report) {
            report_widget.clear ();
            report_widget.set_report (report);
        }

        private void clear_view_tags () {
            foreach (var document in documents) {
                document.editor_window.reset_report_tags ();
            }
        }

        private void update_view_tags (Report report) {
            foreach (var message in report.messages) {
                if (message.source == null) {
                    continue;
                }

                var document = get_document_by_filename (message.source.file.filename);
                if (document != null) {
                    document.editor_window.apply_report_message (message);
                }
            }
        }

        private Document? get_document_by_filename (string filename) {
            foreach (var document in documents) {
                if (document.get_file_path () == filename) {
                    return document;
                }
            }

            return null;
        }

        private void on_show_info_window (Document document, Gtk.TextIter start_iter, int x, int y) {
            var symbol = index.lookup_symbol_at (document.get_file_path (), start_iter.get_line () + 1, start_iter.get_line_offset ());
            if (symbol == null || symbol.name == null) {
                return;
            }          

            info_window.set_current_symbol (symbol);
            info_window.show_at (x, y);
        }
    }
}