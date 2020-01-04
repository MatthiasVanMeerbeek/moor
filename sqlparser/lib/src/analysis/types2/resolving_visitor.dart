part of 'types.dart';

class TypeResolver extends RecursiveVisitor<TypeExpectation, void> {
  final TypeInferenceSession session;

  TypeResolver(this.session);

  void run(AstNode root) {
    visit(root, const NoTypeExpectation());
    session.finish();
  }

  @override
  void visitSelectStatement(SelectStatement e, TypeExpectation arg) {
    _handleWhereClause(e);

    var currentColumnIndex = 0;
    final columnExpectations = arg is SelectTypeExpectation
        ? arg.columnExpectations
        : const <TypeExpectation>[];

    for (final child in e.childNodes) {
      if (child == e.where) continue; // handled above

      if (child is ResultColumn) {
        if (child is ExpressionResultColumn) {
          final expectation = currentColumnIndex < columnExpectations.length
              ? columnExpectations[currentColumnIndex]
              : const NoTypeExpectation();
          visit(child, expectation);

          currentColumnIndex++;
        } else if (child is StarResultColumn) {
          currentColumnIndex += child.scope.availableColumns.length;
        }
      } else {
        visit(child, arg);
      }
    }
  }

  @override
  void visitInsertStatement(InsertStatement e, TypeExpectation arg) {
    if (e.withClause != null) visit(e.withClause, arg);
    visitList(e.targetColumns, const NoTypeExpectation());

    final targets = e.resolvedTargetColumns ?? const [];
    targets.forEach(_handleColumn);

    final expectations = targets.map((r) {
      if (session.graph.knowsType(r)) {
        return ExactTypeExpectation(session.typeOf(r));
      }
      return const NoTypeExpectation();
    }).toList();

    e.source.when(
      isSelect: (select) {
        visit(select.stmt, SelectTypeExpectation(expectations));
      },
      isValues: (values) {
        for (final tuple in values.values) {
          for (var i = 0; i < tuple.expressions.length; i++) {
            final expectation = i < expectations.length
                ? expectations[i]
                : const NoTypeExpectation();
            visit(tuple.expressions[i], expectation);
          }
        }
      },
    );
  }

  @override
  void visitCrudStatement(CrudStatement stmt, TypeExpectation arg) {
    if (stmt is HasWhereClause) {
      final typedStmt = stmt as HasWhereClause;
      _handleWhereClause(typedStmt);
      _visitExcept(stmt, typedStmt.where, arg);
    } else {
      visitChildren(stmt, arg);
    }
  }

  @override
  void visitCreateIndexStatement(CreateIndexStatement e, TypeExpectation arg) {
    _handleWhereClause(e);
    _visitExcept(e, e.where, arg);
  }

  @override
  void visitJoin(Join e, TypeExpectation arg) {
    final constraint = e.constraint;
    if (constraint is OnConstraint) {
      // ON <expr>, <expr> should be boolean
      visit(constraint.expression,
          const ExactTypeExpectation.laxly(ResolvedType.bool()));
      _visitExcept(e, constraint.expression, arg);
    } else {
      visitChildren(e, arg);
    }
  }

  @override
  void visitLiteral(Literal e, TypeExpectation arg) {
    ResolvedType type;

    if (e is NullLiteral) {
      type = const ResolvedType(type: BasicType.nullType, nullable: true);
    } else if (e is StringLiteral) {
      type = e.isBinary
          ? const ResolvedType(type: BasicType.blob)
          : const ResolvedType(type: BasicType.text);
    } else if (e is BooleanLiteral) {
      type = const ResolvedType.bool();
    } else if (e is NumericLiteral) {
      type = e.isInt
          ? const ResolvedType(type: BasicType.int)
          : const ResolvedType(type: BasicType.real);
    }

    session.checkAndResolve(e, type, arg);
  }

  @override
  void visitVariable(Variable e, TypeExpectation arg) {
    final resolved = session.context.stmtOptions.specifiedTypeOf(e) ??
        _inferFromContext(arg);
    if (resolved != null) {
      session.markTypeResolved(e, resolved);
    }
    // todo support when arg is RoughTypeExpectation
    visitChildren(e, arg);
  }

  @override
  void visitUnaryExpression(UnaryExpression e, TypeExpectation arg) {
    final operatorType = e.operator.type;

    if (operatorType == TokenType.plus) {
      // plus is a no-op, so copy type from child
      session.addRelationship(CopyTypeFrom(e, e.inner));
      visit(e.inner, arg);
    } else if (operatorType == TokenType.not) {
      // unary not expression - boolean, but nullability depends on child node.
      session.checkAndResolve(e, const ResolvedType.bool(nullable: null), arg);
      session.addRelationship(NullableIfSomeOtherIs(e, [e.inner]));
      visit(e.inner, const ExactTypeExpectation.laxly(ResolvedType.bool()));
    } else if (operatorType == TokenType.minus) {
      // unary minus - can be int or real depending on child node
      session.addRelationship(CopyAndCast(e, e.inner, CastMode.numeric));
      visit(e.inner, const RoughTypeExpectation.numeric());
    } else if (operatorType == TokenType.tilde) {
      // bitwise negation - definitely int, but nullability depends on child
      session.checkAndResolve(
          e, const ResolvedType(type: BasicType.int, nullable: null), arg);
      session.addRelationship(NullableIfSomeOtherIs(e, [e.inner]));

      visit(e.inner, const NoTypeExpectation());
    } else {
      throw StateError(
          'Unary operator $operatorType not recognized by types2. At $e');
    }
  }

  @override
  void visitBinaryExpression(BinaryExpression e, TypeExpectation arg) {
    switch (e.operator.type) {
      case TokenType.and:
      case TokenType.or:
        session.checkAndResolve(e, const ResolvedType.bool(), arg);
        session.addRelationship(NullableIfSomeOtherIs(e, [e.left, e.right]));

        // logic expressions, so children must be boolean
        visitChildren(e, const ExactTypeExpectation.laxly(ResolvedType.bool()));
        break;
      case TokenType.equal:
      case TokenType.exclamationEqual:
      case TokenType.lessMore:
      case TokenType.less:
      case TokenType.lessEqual:
      case TokenType.more:
      case TokenType.moreEqual:
        // comparison. Returns bool, copying nullability from children.
        session.checkAndResolve(e, const ResolvedType.bool(), arg);
        session.addRelationship(NullableIfSomeOtherIs(e, [e.left, e.right]));
        // Not technically a requirement, but assume lhs and rhs have the same
        // type.
        session.addRelationship(HaveSameType(e.left, e.right));
        visitChildren(e, arg);
        break;
      case TokenType.plus:
      case TokenType.minus:
        session.addRelationship(CopyEncapsulating(e, [e.left, e.right]));
        break;
      // all of those only really make sense for integers
      case TokenType.shiftLeft:
      case TokenType.shiftRight:
      case TokenType.pipe:
      case TokenType.ampersand:
      case TokenType.percent:
        const type = ResolvedType(type: BasicType.int);
        session.checkAndResolve(e, type, arg);
        session.addRelationship(NullableIfSomeOtherIs(e, [e.left, e.right]));
        visitChildren(e, const ExactTypeExpectation.laxly(type));
        break;
      case TokenType.doublePipe:
        // string concatenation.
        const stringType = ResolvedType(type: BasicType.text);
        session.checkAndResolve(e, stringType, arg);
        session.addRelationship(NullableIfSomeOtherIs(e, [e.left, e.right]));
        const childExpectation = ExactTypeExpectation.laxly(stringType);
        visit(e.left, childExpectation);
        visit(e.right, childExpectation);
        break;
      default:
        throw StateError('Binary operator ${e.operator.type} not recognized '
            'by types2. At $e');
    }
  }

  @override
  void visitIsExpression(IsExpression e, TypeExpectation arg) {
    session.checkAndResolve(e, const ResolvedType.bool(), arg);
    session.hintNullability(e, false);
    visitChildren(e, const NoTypeExpectation());
  }

  @override
  void visitCastExpression(CastExpression e, TypeExpectation arg) {
    final type = session.context.schemaSupport.resolveColumnType(e.typeName);
    session.checkAndResolve(e, type, arg);
    session.addRelationship(NullableIfSomeOtherIs(e, [e.operand]));
    visit(e.operand, const NoTypeExpectation());
  }

  @override
  void visitReference(Reference e, TypeExpectation arg) {
    final resolved = e.resolvedColumn;
    if (resolved == null) return;

    _handleColumn(resolved);
    _lazyCopy(e, resolved);
  }

  void _handleColumn(Column column) {
    if (session.graph.knowsType(column)) return;

    if (column is TableColumn) {
      session.markTypeResolved(column, column.type);
    } else if (column is ExpressionColumn) {
      _lazyCopy(column, column.expression);
    } else if (column is DelegatedColumn && column.innerColumn != null) {
      _handleColumn(column.innerColumn);
      _lazyCopy(column, column.innerColumn);
    }
  }

  void _lazyCopy(Typeable to, Typeable from) {
    if (session.graph.knowsType(from)) {
      session.markTypeResolved(to, session.typeOf(from));
    } else {
      session.addRelationship(CopyTypeFrom(to, from));
    }
  }

  void _handleWhereClause(HasWhereClause stmt) {
    if (stmt.where != null) {
      // assume that a where statement is a boolean expression. Sqlite
      // internally casts (https://www.sqlite.org/lang_expr.html#booleanexpr),
      // so be lax
      visit(stmt.where, const ExactTypeExpectation.laxly(ResolvedType.bool()));
    }
  }

  void _visitExcept(AstNode node, AstNode skip, TypeExpectation arg) {
    for (final child in node.childNodes) {
      if (child != skip) {
        visit(child, arg);
      }
    }
  }

  ResolvedType _inferFromContext(TypeExpectation expectation) {
    if (expectation is ExactTypeExpectation) {
      return expectation.type;
    }
    return null;
  }
}